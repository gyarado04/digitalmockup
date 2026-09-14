# -*- coding: utf-8 -*-
"""Script exécuté par Blender en mode background, jamais importé par l'app.

    blender -b template.blend --python headless.py -- <commande> <config.json>

Commandes :
    list_shots               — énumère les caméras de la scène + rendu d'une
                                miniature basse résolution par caméra
    render                   — synchro textures par frame + rendu animé ; le
                                scroll de chaque page est calculé automatique-
                                ment (0.0→1.0 linéaire sur frame_start..
                                frame_end), aucune keyframe à poser à la main

Les résultats exploitables sont émis sur stdout entre les marqueurs
AGENCE_RESULT_BEGIN / AGENCE_RESULT_END (JSON sur une seule ligne), pour que
l'app puisse les extraire au milieu des logs normaux de Blender.

La logique de synchro (mapping scale, scroll, remplacement de texture) est
reprise telle quelle de l'addon agence_template_3d.py — seule la source des
données change : un fichier JSON écrit par l'app au lieu des PropertyGroups.
"""

import bpy
import glob
import json
import os
import re
import sys
import tempfile

# ─────────────────────────────────────────────────────────────
# CONSTANTES — identiques à l'addon
# ─────────────────────────────────────────────────────────────

NOM_MATERIAL = "Interface"
NOM_NOEUD_DESKTOP = "Capture_desktop"
NOM_NOEUD_MOBILE = "Capture_mobile"
NOM_OBJET_ECRAN_VERRE = "Ecran verre"

DESKTOP_HEIGHT = 1080
MOBILE_HEIGHT = 844

# Largeur de viewport CSS demandée à la capture (WebCapture.swift,
# AppState.capturePage) — sert à détecter le facteur d'échelle réel de
# l'image chargée (voir update_mapping_scale_for_full_page) : WKWebView
# capture au facteur d'échelle de l'écran (Retina = 2x sur ce Mac), donc une
# capture desktop demandée à 1920 CSS px produit une image PNG de 3840px de
# large, pas 1920. DESKTOP_HEIGHT/MOBILE_HEIGHT ci-dessus sont en pixels
# "1x" (CSS) — sans cette correction, la fenêtre de recadrage verticale est
# deux fois trop petite sur une capture Retina, et le contenu affiché à
# l'écran apparaît anormalement zoomé/étiré verticalement.
DESKTOP_WIDTH = 1920
MOBILE_WIDTH = 390

# fps de capture de WebCapture.swift:captureFrameSequence (2026-09-08,
# séquence d'images animée qui préserve le MOUVEMENT des animations
# d'apparition au scroll — une image fixe pleine page ne peut montrer que
# leur état final, jamais leur apparition). Sert à convertir la DURÉE
# RÉELLE d'une séquence (frame_count / ce fps) en nombre de frames Blender
# équivalent pour le scroll par défaut (scroll_frames_for_page) — PAS le
# fps du RENDU (scene.render.fps), même si la valeur coïncide ici (24,
# voir commentaire côté Swift : 8fps essayé d'abord, jugé "super saccadé"
# sur un vrai rendu, chaque frame capturée restant affichée ~3 frames de
# rendu d'affilée à 24fps de rendu).
SEQUENCE_CAPTURE_FPS = 24

# Vitesse de scroll — secondes pour défiler l'équivalent d'UNE hauteur
# d'écran (viewport desktop), CONSTANTE quelle que soit la hauteur totale de
# la page. Pas une durée fixe pour toute la page (ancienne version buguée :
# une page 3x plus longue qu'une autre défilait à la même vitesse absolue,
# donc visuellement bien plus vite puisqu'il fallait couvrir 3x plus de
# pixels dans le même temps). Une page qui ne tient pas dans le nombre de
# frames de son plan n'atteint simplement pas le bas (normal pour un plan
# bref) ; une page qui tient largement atteint 1.0 et y reste jusqu'à la fin
# de son plan — jamais de scroll complet forcé dans une fenêtre trop courte.
SECONDS_PER_VIEWPORT_HEIGHT = 4.0

TEST_ENGINE = 'BLENDER_EEVEE_NEXT'
TEST_RES_X = 1920
TEST_RES_Y = 1080
TEST_RES_PERCENT = 50
# Plage de frames : la même que le rendu final (FINAL_FRAME_START/END,
# 1-900, toute la plage possible du template) — Test ne s'en distingue plus
# que par le moteur/la résolution/la qualité, plus par une fenêtre de frames
# fixe à part. cmd_render ne rend de toute façon que les plages des plans
# réellement assignés à une page (voir _blocks_to_render) : un test avec peu
# de plans assignés reste rapide, un test avec beaucoup de plans couvre tout
# ce qui est réellement utile à prévisualiser, comme le rendu final.
TEST_FFMPEG_FORMAT = 'MPEG4'
TEST_FFMPEG_CODEC = 'H264'
TEST_FFMPEG_QUALITY = 'MEDIUM'

FINAL_ENGINE = 'CYCLES'
FINAL_NOISE_THRESHOLD = 0.01
FINAL_MAX_SAMPLES = 50
FINAL_RES_X = 3840
FINAL_RES_Y = 2160
FINAL_RES_PERCENT = 200
FINAL_FRAME_START = 1
FINAL_FRAME_END = 900
FINAL_FFMPEG_FORMAT = 'MPEG4'
FINAL_FFMPEG_CODEC = 'H264'
FINAL_FFMPEG_QUALITY = 'HIGH'


def emit_result(payload):
    """JSON sur une ligne, encadré de marqueurs, au milieu des logs Blender."""
    sys.stdout.write("\nAGENCE_RESULT_BEGIN%sAGENCE_RESULT_END\n" % json.dumps(payload))
    sys.stdout.flush()


# ─────────────────────────────────────────────────────────────
# LOGIQUE PORTÉE DE L'ADDON — noeuds / mapping / textures
# ─────────────────────────────────────────────────────────────

def find_image_node(material_name, node_name):
    mat = bpy.data.materials.get(material_name)
    if mat is None or mat.node_tree is None:
        return None
    return mat.node_tree.nodes.get(node_name)


def get_connected_mapping_node(image_node):
    if image_node is None:
        return None
    vector_input = image_node.inputs.get('Vector')
    if vector_input is None or not vector_input.is_linked:
        return None
    return vector_input.links[0].from_node


def update_mapping_scale_for_full_page(image_node, target_height_px, expected_width_px):
    """Recalcule le Scale Y du Mapping node pour n'afficher qu'une tranche
    d'un écran d'une capture pleine page (voir addon pour le détail).

    `target_height_px`/`expected_width_px` sont en pixels "1x" (CSS, ceux
    demandés à la capture — voir DESKTOP_WIDTH/MOBILE_WIDTH). L'image
    réellement chargée peut avoir été capturée à une échelle différente
    (Retina = 2x) : on le détecte via sa largeur RÉELLE / largeur CSS
    demandée, et on corrige la hauteur cible en conséquence — sinon la
    fenêtre de recadrage est trop petite d'un facteur 2 sur une capture
    Retina, et le contenu apparaît zoomé/étiré verticalement à l'écran."""
    mapping_node = get_connected_mapping_node(image_node)
    if mapping_node is None or mapping_node.type != 'MAPPING':
        return False
    if image_node.image is None or image_node.image.size[1] == 0 or image_node.image.size[0] == 0:
        return False

    capture_scale = image_node.image.size[0] / expected_width_px
    ratio = (target_height_px * capture_scale) / image_node.image.size[1]
    scale_input = mapping_node.inputs.get('Scale')
    if scale_input is None:
        return False

    current_y = scale_input.default_value[1]
    sign = -1.0 if current_y < 0 else 1.0
    scale_input.default_value[1] = sign * ratio
    return True


def apply_scroll_position(image_node, scroll_fraction):
    """0 = haut de page, 1 = bas — déplace Location Y du Mapping node en
    respectant la tranche visible définie par Scale Y."""
    mapping_node = get_connected_mapping_node(image_node)
    if mapping_node is None or mapping_node.type != 'MAPPING':
        return False

    scale_input = mapping_node.inputs.get('Scale')
    location_input = mapping_node.inputs.get('Location')
    if scale_input is None or location_input is None:
        return False

    scale_y = scale_input.default_value[1]
    r = abs(scale_y)

    if scale_y < 0:
        location_y = 1.0 - scroll_fraction * (1.0 - r)
    else:
        location_y = (1.0 - r) * (1.0 - scroll_fraction)

    location_input.default_value[1] = location_y
    return True


def replace_image_sequence_on_node(node, sequence_dir):
    """Charge un DOSSIER de frames numérotées (`frame_0001.png`, ...) comme
    texture ANIMÉE sur `node` — remplace `replace_image_on_node` pour une
    page capturée en séquence d'images plutôt qu'en image fixe pleine page
    (2026-09-08, voir WebCapture.swift:captureFrameSequence : préserve le
    MOUVEMENT des animations d'apparition au scroll, qu'une image fixe ne
    peut montrer que déjà terminées). Chaque frame de la séquence est DÉJÀ
    cadrée à la taille du viewport (capturée en scrollant réellement) —
    pas besoin du Mapping node pour "simuler" un recadrage/scroll comme
    pour une image pleine page, voir `reset_mapping_identity` et
    `apply_sequence_frame`.

    Retourne (ok, message, frame_count) — `frame_count` nécessaire à
    `apply_sequence_frame` pour borner la recherche de frame."""
    if node is None or node.type != 'TEX_IMAGE':
        return False, "Noeud introuvable ou incompatible", 0
    first_frame = os.path.join(sequence_dir, "frame_0001.png")
    if not os.path.exists(first_frame):
        return False, "Séquence manquante : %s" % first_frame, 0
    frame_count = len(glob.glob(os.path.join(sequence_dir, "frame_*.png")))
    if frame_count == 0:
        return False, "Dossier de séquence vide : %s" % sequence_dir, 0

    if node.image is None:
        node.image = bpy.data.images.load(first_frame, check_existing=False)
    else:
        node.image.filepath = first_frame
        node.image.source = 'FILE'
        node.image.reload()
    node.image.source = 'SEQUENCE'
    node.image_user.frame_duration = frame_count
    node.image_user.use_auto_refresh = True
    node.image.name = os.path.basename(sequence_dir)
    return True, "OK", frame_count


def apply_sequence_frame(node, fraction, frame_count, current_blender_frame):
    """0.0→1.0 -> quelle frame de la séquence afficher MAINTENANT — même
    formule validée pour un pilotage de vidéo (essayé puis abandonné au
    profit de cette approche plus simple, 2026-09-08, voir mémoire projet) :
    `image_user.frame_start` = frame Blender courante (annule le terme
    "scene_frame - frame_start + 1" à 1), `image_user.frame_offset` =
    frame cible - 1 (Blender compte les frames de séquence à partir de 1).
    Doit être réappliqué à CHAQUE frame — `frame_start` dépend de la frame
    Blender courante, qui change à chaque appel."""
    if node is None or node.type != 'TEX_IMAGE' or node.image is None or frame_count <= 0:
        return False
    target = max(1, min(frame_count, round(1 + fraction * (frame_count - 1))))
    node.image_user.frame_start = current_blender_frame
    node.image_user.frame_offset = target - 1
    return True


def reset_mapping_identity(image_node):
    """Remet le Mapping node à l'identité EN MAGNITUDE (Scale.Y=±1) — une
    page en séquence d'images n'a PAS besoin du recadrage/scroll simulé
    par ce noeud (chaque frame de la séquence est déjà cadrée au
    viewport, voir `replace_image_sequence_on_node`) ; ce mécanisme ne
    sert que pour une image fixe pleine page
    (`update_mapping_scale_for_full_page`/`apply_scroll_position`).

    Bug corrigé le 2026-09-08, en 2 temps ("la vidéo est à l'envers" puis
    "l'écran est noir") :
    1. Forcer Scale.Y à +1.0 pile ignorait que CE TEMPLATE (comme
       d'autres) a un Scale.Y par défaut NÉGATIF sur ce noeud (`-0.229`
       sur "tablette" côté desktop, orientation de l'écran/du maillage)
       — un signe qui fait PARTIE du réglage d'origine du template, pas
       un artefact du recadrage pleine page. Même logique de
       préservation du signe que `update_mapping_scale_for_full_page`
       (`sign = -1.0 if current_y < 0 else 1.0`) : on ne connaît QUE
       cette valeur, jamais un signe universel valable pour tous les
       templates (le noeud mobile de "tablette", par exemple, a lui un
       Scale.Y par défaut POSITIF).
    2. Une fois le signe corrigé, poser Location.Y à 0 SANS CONDITION
       (comme avant) donnait un écran NOIR pour un Scale.Y négatif :
       avec Scale=-1/Location=0, la coordonnée V échantillonnée sort de
       [0,1] (V' = -V, négatif pour tout V>0) — hors image, donc
       noir/coupé selon le mode d'extension de la texture. Il FAUT une
       Location.Y qui compense le signe (V' = 1-V pour rester dans
       [0,1] quand Scale=-1) — exactement ce que calcule DÉJÀ
       `apply_scroll_position` pour n'importe quel signe de Scale (sa
       branche `if scale_y < 0: location_y = 1.0 - fraction*(1-r)`) :
       plutôt que réinventer ce calcul (mal, la 1ère fois), on
       RÉUTILISE cette fonction avec `fraction=0.0` (une séquence n'a
       pas besoin de scroll simulé, juste de la bonne frame — voir
       `apply_sequence_frame` — donc toujours "fraction 0" ici)."""
    mapping_node = get_connected_mapping_node(image_node)
    if mapping_node is None or mapping_node.type != 'MAPPING':
        return
    scale_input = mapping_node.inputs.get('Scale')
    if scale_input is not None:
        current_y = scale_input.default_value[1]
        sign = -1.0 if current_y < 0 else 1.0
        scale_input.default_value[1] = sign
    apply_scroll_position(image_node, 0.0)


def sequence_capture_fps(sequence_dir):
    """fps RÉELLEMENT utilisé pour capturer CETTE séquence précise — lu
    depuis `sequence_meta.json`, écrit par
    `WebCapture.swift:captureFrameSequence` à côté des frames. PAS la
    constante globale `SEQUENCE_CAPTURE_FPS` directement : bug corrigé le
    2026-09-08 ("la vidéo est en accéléré") — en faisant passer cette
    constante de 8 à 24 (pour corriger un souci de saccades), les
    séquences DÉJÀ capturées à 8fps se sont retrouvées réinterprétées à
    tort comme si elles duraient 3x moins longtemps (rejouées 3x trop
    vite). Chaque séquence fige désormais son propre fps de capture à la
    volée — insensible à un futur changement de cette constante. Repli
    sur `SEQUENCE_CAPTURE_FPS` uniquement si le sidecar est absent (une
    séquence capturée avant l'ajout de ce fichier, ou fichier corrompu/
    illisible)."""
    meta_path = os.path.join(sequence_dir, "sequence_meta.json")
    try:
        with open(meta_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        fps = float(data.get("fps"))
        if fps > 0:
            return fps
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        pass
    return SEQUENCE_CAPTURE_FPS


def sync_texture_node(node, path, target_height_px, expected_width_px):
    """Charge `path` sur `node` — image fixe pleine page (fichier) OU
    séquence animée (dossier), auto-détecté via `os.path.isdir` (pas de
    clé JSON dédiée : Swift décide du type simplement en écrivant soit un
    fichier soit un dossier, voir `Project.pageDesktopPath`/
    `WebCapture.captureFrameSequence`). Fonction MODULE-LEVEL (pas une
    méthode de `PageSync`) : utilisée à la fois par `PageSync.sync_textures`
    (rendu animé) et `cmd_color_preview` (un seul still).

    Retourne (ok, frame_count) — `frame_count` vaut 0 pour une image fixe
    (pas de séquence, `apply_scroll_position` reste la bonne fonction à
    utiliser ensuite)."""
    if os.path.isdir(path):
        ok, _msg, frame_count = replace_image_sequence_on_node(node, path)
        if ok:
            reset_mapping_identity(node)
        return ok, frame_count
    ok, _msg = replace_image_on_node(node, path)
    if ok:
        update_mapping_scale_for_full_page(node, target_height_px, expected_width_px)
    return ok, 0


def _srgb_to_linear(c):
    """Un hex #RRGGBB choisi dans un color picker macOS est en sRGB, mais
    Principled BSDF > Base Color attend du linéaire — sans cette
    conversion, la couleur appliquée au rendu serait visiblement plus
    sombre/désaturée que celle choisie à l'écran."""
    c = max(0.0, min(1.0, c))
    if c <= 0.04045:
        return c / 12.92
    return ((c + 0.055) / 1.055) ** 2.4


def hex_to_linear_rgba(hex_color):
    """'#RRGGBB' (ou sans '#') -> (r, g, b, 1.0) linéaire, None si invalide
    — jamais lever d'exception ici, une dérogation de couleur mal formée
    ne doit pas faire échouer tout le rendu."""
    if not hex_color:
        return None
    s = hex_color.lstrip('#')
    if len(s) != 6:
        return None
    try:
        r = int(s[0:2], 16) / 255.0
        g = int(s[2:4], 16) / 255.0
        b = int(s[4:6], 16) / 255.0
    except ValueError:
        return None
    return (_srgb_to_linear(r), _srgb_to_linear(g), _srgb_to_linear(b), 1.0)


def apply_color_override(material_names, hex_color):
    """Écrase le Base Color du Principled BSDF de chaque matériau nommé —
    utilisé pour les color pickers "Fond"/"Tablette" des réglages avancés
    (voir Project.backgroundColorHex/deviceColorHex côté Swift). Silencieux
    si le matériau ou le noeud n'existe pas dans ce template (tous les
    presets n'ont pas forcément les mêmes noms de matériaux)."""
    rgba = hex_to_linear_rgba(hex_color)
    if rgba is None:
        return
    for name in material_names:
        mat = bpy.data.materials.get(name)
        if mat is None or mat.node_tree is None:
            continue
        for node in mat.node_tree.nodes:
            if node.type == 'BSDF_PRINCIPLED':
                node.inputs['Base Color'].default_value = rgba


def replace_image_on_node(node, filepath):
    if node is None or node.type != 'TEX_IMAGE':
        return False, "Noeud introuvable ou incompatible"
    if not os.path.exists(filepath):
        return False, "Fichier manquant : %s" % filepath

    if node.image is None:
        node.image = bpy.data.images.load(filepath, check_existing=False)
    else:
        node.image.filepath = filepath
        node.image.source = 'FILE'
        node.image.reload()

    node.image.name = os.path.basename(filepath)
    return True, "OK"


def _set_render_engine(render, engine_id):
    candidates = [engine_id]
    if engine_id == 'BLENDER_EEVEE_NEXT':
        candidates.append('BLENDER_EEVEE')
    for candidate in candidates:
        try:
            render.engine = candidate
            return
        except TypeError:
            continue


def _set_image_format(image_settings, file_format):
    """
    Pose `image_settings.file_format`, compatible Blender 4.x ET 5.x.

    Changement d'API en Blender 5.0 (constaté le 2026-09-11 : rendu qui
    échoue systématiquement avec `enum "FFMPEG" not found in ('AVIF',
    'JPEG', 'OPEN_EXR', 'PNG', ...)` — testé avec la 5.2.1) :
    `image_settings` a désormais une propriété `media_type`
    ('IMAGE'/'MULTI_LAYER_IMAGE'/'VIDEO') qui FILTRE les valeurs
    acceptées par `file_format` — 'FFMPEG' n'apparaît dans l'énum QUE si
    `media_type == 'VIDEO'` a été posé AVANT (confirmé en isolant le
    problème directement via `Blender --background --python-expr`).
    `media_type` n'existe PAS en Blender 4.x — `hasattr` protège, donc
    cette fonction marche sur les 2 versions sans branche explicite par
    version majeure. Utilisée PARTOUT où ce projet pose `file_format`
    (mode test/final, vignettes de plans, assemblage final, aperçu
    couleur) plutôt que l'assignation directe, pour ne pas avoir à
    répéter ce garde-fou à chaque appel.
    """
    if hasattr(image_settings, "media_type"):
        image_settings.media_type = 'VIDEO' if file_format == 'FFMPEG' else 'IMAGE'
    image_settings.file_format = file_format


def apply_render_mode_settings(scene, mode):
    render = scene.render

    ecran_verre = bpy.data.objects.get(NOM_OBJET_ECRAN_VERRE)
    if ecran_verre is not None:
        ecran_verre.hide_render = (mode == 'TEST')

    if mode == 'TEST':
        _set_render_engine(render, TEST_ENGINE)
        render.resolution_x = TEST_RES_X
        render.resolution_y = TEST_RES_Y
        render.resolution_percentage = TEST_RES_PERCENT
        scene.frame_start = FINAL_FRAME_START
        scene.frame_end = FINAL_FRAME_END
        _set_image_format(render.image_settings, 'FFMPEG')
        render.ffmpeg.format = TEST_FFMPEG_FORMAT
        render.ffmpeg.codec = TEST_FFMPEG_CODEC
        render.ffmpeg.constant_rate_factor = TEST_FFMPEG_QUALITY
    else:  # 'FINAL'
        _set_render_engine(render, FINAL_ENGINE)
        if hasattr(scene, "cycles"):
            scene.cycles.samples = FINAL_MAX_SAMPLES
            scene.cycles.adaptive_threshold = FINAL_NOISE_THRESHOLD
        render.resolution_x = FINAL_RES_X
        render.resolution_y = FINAL_RES_Y
        render.resolution_percentage = FINAL_RES_PERCENT
        scene.frame_start = FINAL_FRAME_START
        scene.frame_end = FINAL_FRAME_END
        _set_image_format(render.image_settings, 'FFMPEG')
        render.ffmpeg.format = FINAL_FFMPEG_FORMAT
        render.ffmpeg.codec = FINAL_FFMPEG_CODEC
        render.ffmpeg.constant_rate_factor = FINAL_FFMPEG_QUALITY


# ─────────────────────────────────────────────────────────────
# SYNCHRO CAMÉRA → PAGE (version pilotée par le config JSON)
# ─────────────────────────────────────────────────────────────

class PageSync:
    """État de la synchro pendant le rendu : quelle page est chargée, où
    sont ses captures. Le scroll n'est plus gardé en mémoire ni keyframé à
    l'avance — il se calcule automatiquement comme une fraction linéaire
    0.0→1.0, à VITESSE CONSTANTE (SECONDS_PER_VIEWPORT_HEIGHT, voir
    scroll_frames_for_page) et adaptée à la vraie fenêtre d'apparition de
    CHAQUE page (voir build_segments) : une page qui ne tient pas dans son
    plan n'atteint simplement pas le bas plutôt que d'être forcée."""

    def __init__(self, config, fps):
        self.pages = config["pages"]           # [{uid, name, cameras, desktop_path, mobile_path}]
        self.fps = fps
        self.last_uid = None
        self._scroll_frames_cache = {}         # page uid -> frames pour défiler cette page en entier
        # page uid -> {"desktop": frame_count, "mobile": frame_count} — 0
        # si cet axe est une image fixe (pas une séquence), voir
        # sync_texture_node/apply_frame. Rempli par sync_textures.
        self._sequence_frame_counts = {}
        self.camera_to_page = {}
        for page in self.pages:
            for cam_name in page.get("cameras", []):
                if cam_name:
                    self.camera_to_page[cam_name] = page

    def page_for_camera(self, camera_obj):
        if camera_obj is None:
            return None
        return self.camera_to_page.get(camera_obj.name)

    def sync_textures(self, page):
        if self.last_uid == page["uid"]:
            return
        node_desktop = find_image_node(NOM_MATERIAL, NOM_NOEUD_DESKTOP)
        node_mobile = find_image_node(NOM_MATERIAL, NOM_NOEUD_MOBILE)

        # `sync_texture_node` détecte lui-même image fixe (fichier) vs
        # séquence animée (dossier) — voir son commentaire. `frame_count_*`
        # vaut 0 pour une image fixe (pas de séquence).
        ok_d, frame_count_d = sync_texture_node(node_desktop, page["desktop_path"], DESKTOP_HEIGHT, DESKTOP_WIDTH)
        ok_m, frame_count_m = sync_texture_node(node_mobile, page["mobile_path"], MOBILE_HEIGHT, MOBILE_WIDTH)
        self._sequence_frame_counts[page["uid"]] = {"desktop": frame_count_d, "mobile": frame_count_m}

        if ok_d and ok_m:
            self.last_uid = page["uid"]

    def build_segments(self, scene, frame_start, frame_end):
        """Liste de segments contigus (start, end, page_uid) : une plage de
        frames continue où la même page reste affichée. S'appuie sur les
        marqueurs caméra de la timeline (Blender : lier une caméra à un
        marqueur, "Ctrl+B" dans le Dope Sheet) — le mécanisme natif qui fait
        déjà changer scene.camera au fil du temps, sans rien inventer côté
        app. Sans marqueur caméra (une seule caméra fixe sur tout le
        rendu), un seul segment couvre toute la plage — comportement
        identique à avant pour les templates à une seule caméra."""
        markers = sorted(
            (m for m in scene.timeline_markers if m.camera is not None),
            key=lambda m: m.frame,
        )

        raw = []
        if not markers:
            page = self.page_for_camera(scene.camera)
            raw.append((frame_start, frame_end, page["uid"] if page else None))
        else:
            if markers[0].frame > frame_start:
                page = self.page_for_camera(scene.camera)
                raw.append((frame_start, markers[0].frame - 1, page["uid"] if page else None))
            for i, marker in enumerate(markers):
                seg_start = max(marker.frame, frame_start)
                seg_end = markers[i + 1].frame - 1 if i + 1 < len(markers) else frame_end
                seg_end = min(seg_end, frame_end)
                if seg_start > seg_end:
                    continue
                page = self.page_for_camera(marker.camera)
                raw.append((seg_start, seg_end, page["uid"] if page else None))

        # Fusionne les segments consécutifs de la même page (ex. plusieurs
        # plans/caméras qui se suivent sur une seule page) : un seul cycle
        # de scroll continu sur toute son apparition, pas un par plan.
        segments = []
        for seg in raw:
            if segments and segments[-1][2] == seg[2]:
                segments[-1] = (segments[-1][0], seg[1], seg[2])
            else:
                segments.append(seg)
        return segments

    def scroll_frames_for_page(self, page):
        """Nombre de frames pour défiler CETTE page en entier (haut → bas),
        à vitesse constante (SECONDS_PER_VIEWPORT_HEIGHT par hauteur d'écran
        desktop) — dépend de la vraie hauteur de sa capture, donc varie
        d'une page à l'autre (une page 3x plus haute prend 3x plus de
        frames, pas la même durée absolue). N'appeler qu'après
        sync_textures(page) pour cette page. Mis en cache par uid.

        Séquence d'images (voir sync_texture_node) : sa durée RÉELLE de
        capture (frame_count / fps RÉEL de CETTE séquence, voir
        `sequence_capture_fps` — PAS une constante globale fixe) EST DÉJÀ
        le bon rythme — capturée en scrollant réellement à ce même repère
        visuel, voir WebCapture.swift:captureFrameSequence — donc juste
        convertir cette durée réelle en nombre de frames Blender (fps du
        RENDU, pas celui de la capture) plutôt que de recalculer depuis
        une hauteur de page (qui n'a plus de sens : l'image chargée sur le
        noeud est alors une frame de la taille du viewport, pas la page
        entière)."""
        uid = page["uid"]
        if uid in self._scroll_frames_cache:
            return self._scroll_frames_cache[uid]

        sequence_frame_count = self._sequence_frame_counts.get(uid, {}).get("desktop", 0)
        if sequence_frame_count > 0:
            capture_fps = sequence_capture_fps(page["desktop_path"])
            duration_seconds = sequence_frame_count / capture_fps
            frames = max(1, round(duration_seconds * self.fps))
            self._scroll_frames_cache[uid] = frames
            return frames

        node_desktop = find_image_node(NOM_MATERIAL, NOM_NOEUD_DESKTOP)
        page_height_px = None
        if node_desktop is not None and node_desktop.image is not None:
            page_height_px = node_desktop.image.size[1]

        if not page_height_px or page_height_px <= DESKTOP_HEIGHT:
            frames = 1  # rien à défiler : la page tient dans un seul écran
        else:
            scrollable_px = page_height_px - DESKTOP_HEIGHT
            px_per_second = DESKTOP_HEIGHT / SECONDS_PER_VIEWPORT_HEIGHT
            frames = max(1, round(scrollable_px / px_per_second * self.fps))

        self._scroll_frames_cache[uid] = frames
        return frames

    @staticmethod
    def scroll_fraction(segments, frame, scroll_frames):
        """0.0 au début du segment qui contient `frame`, puis avance à
        vitesse constante (scroll_frames pour parcourir toute la page,
        indépendant de la durée du segment) — plafonné à 1.0. Une page
        visible moins longtemps que scroll_frames n'atteint pas le bas
        (normal pour un plan bref) plutôt que d'être forcée à un scroll
        complet illisible dans une fenêtre trop courte."""
        for start, end, _uid in segments:
            if start <= frame <= end:
                if scroll_frames <= 0:
                    return 1.0
                return max(0.0, min(1.0, (frame - start) / scroll_frames))
        return 0.0

    def apply_frame(self, scene, segments, frame=None):
        """`frame` optionnel : la frame RÉELLE à utiliser pour le calcul du
        scroll (segments/marqueurs sont indexés sur les vrais numéros de
        frame). Par défaut (None) : `scene.frame_current`, comme avant —
        seul le rendu segmenté (cmd_render, axe de frames virtuel compact
        quand des plans ne sont assignés à aucune page) a besoin de le
        préciser explicitement, puisque `scene.frame_current` y vaut alors
        la frame VIRTUELLE, pas la vraie."""
        page = self.page_for_camera(scene.camera)
        if page is None:
            return
        self.sync_textures(page)
        node_desktop = find_image_node(NOM_MATERIAL, NOM_NOEUD_DESKTOP)
        node_mobile = find_image_node(NOM_MATERIAL, NOM_NOEUD_MOBILE)
        current_frame = scene.frame_current if frame is None else frame

        # Scroll auto à vitesse constante, comportement d'origine, partagé
        # par les 2 axes — "Assigner un plan à une section" (introduit le
        # 2026-09-07) RETIRÉ le 2026-09-08, demande explicite de
        # l'utilisateur (`camera_own_segment`/`camera_section_fraction`
        # supprimées avec).
        scroll_frames = self.scroll_frames_for_page(page)
        fraction = self.scroll_fraction(segments, current_frame, scroll_frames)

        # Séquence d'images (voir sync_texture_node) : afficher la bonne
        # FRAME de la séquence plutôt que déplacer un Mapping node — sinon,
        # comportement historique inchangé (image fixe pleine page).
        counts = self._sequence_frame_counts.get(page["uid"], {"desktop": 0, "mobile": 0})
        if counts["desktop"] > 0:
            apply_sequence_frame(node_desktop, fraction, counts["desktop"], current_frame)
        else:
            apply_scroll_position(node_desktop, fraction)
        if counts["mobile"] > 0:
            apply_sequence_frame(node_mobile, fraction, counts["mobile"], current_frame)
        else:
            apply_scroll_position(node_mobile, fraction)


# ─────────────────────────────────────────────────────────────
# COMMANDES
# ─────────────────────────────────────────────────────────────

def _safe_filename(name):
    name = re.sub(r'[^\w\-. ]', '_', name or "")
    return name or "shot"


# Réglages de la miniature de plan — volontairement légers, ce n'est qu'un
# aperçu pour choisir une caméra dans l'app, pas un rendu livrable
SHOT_THUMB_RES_X = 320
SHOT_THUMB_RES_Y = 180
SHOT_THUMB_SAMPLES = 16


def _camera_segment_frames(scene, frame_start, frame_end):
    """Nombre de frames du segment de timeline associé à chaque caméra
    (marqueur "bind camera to markers", même règle que PageSync.build_
    segments) — permet à l'app d'estimer la durée du rendu d'après les
    plans réellement choisis (mode libre), sans avoir besoin de lancer un
    rendu complet pour le savoir. Une caméra sans marqueur (scène à une
    seule caméra fixe) n'a simplement pas d'entrée ici."""
    markers = sorted(
        (m for m in scene.timeline_markers if m.camera is not None),
        key=lambda m: m.frame,
    )
    totals = {}
    for i, marker in enumerate(markers):
        seg_start = max(marker.frame, frame_start)
        seg_end = markers[i + 1].frame - 1 if i + 1 < len(markers) else frame_end
        seg_end = min(seg_end, frame_end)
        if seg_start > seg_end:
            continue
        totals[marker.camera.name] = totals.get(marker.camera.name, 0) + (seg_end - seg_start + 1)
    return totals


def cmd_list_shots(config):
    """Énumère les caméras de la scène et rend, pour chacune, une miniature
    basse résolution — pour que l'app puisse afficher une grille "quel plan
    montre quoi" plutôt qu'une simple liste de noms.

    Réglages de rendu sauvegardés/restaurés autour de l'opération : cette
    commande ne resauvegarde jamais le .blend (contrairement à 'keyframe'),
    donc les mutations de scene.render ne doivent pas fuiter au cas où
    l'appelant réutiliserait la même session Blender (pas le cas ici, mais
    coûte rien de rester propre)."""
    scene = bpy.context.scene
    cache_dir = config.get("cache_dir")
    cameras = [obj for obj in scene.objects if obj.type == 'CAMERA']

    if not cache_dir or not cameras:
        emit_result({"ok": True, "shots": []})
        return

    os.makedirs(cache_dir, exist_ok=True)

    render = scene.render
    original_camera = scene.camera
    original_engine = render.engine
    original_res_x, original_res_y = render.resolution_x, render.resolution_y
    original_pct = render.resolution_percentage
    original_filepath = render.filepath
    original_format = render.image_settings.file_format

    _set_render_engine(render, TEST_ENGINE)
    render.resolution_x = SHOT_THUMB_RES_X
    render.resolution_y = SHOT_THUMB_RES_Y
    render.resolution_percentage = 100
    _set_image_format(render.image_settings, 'PNG')
    if hasattr(scene, "eevee"):
        # Nom de la propriété selon la version (EEVEE Next vs ancien EEVEE)
        for attr in ("taa_render_samples", "samples"):
            if hasattr(scene.eevee, attr):
                setattr(scene.eevee, attr, SHOT_THUMB_SAMPLES)
                break

    segment_frames = _camera_segment_frames(scene, FINAL_FRAME_START, FINAL_FRAME_END)
    fps = scene.render.fps / scene.render.fps_base if scene.render.fps_base else scene.render.fps

    shots = []
    try:
        for cam in sorted(cameras, key=lambda o: o.name):
            scene.camera = cam
            thumb_path = os.path.join(cache_dir, _safe_filename(cam.name) + ".png")
            render.filepath = thumb_path
            try:
                bpy.ops.render.render(write_still=True)
            except Exception as exc:
                print("AGENCE_WARN thumbnail %s: %s" % (cam.name, exc))
                thumb_path = None
            shots.append({
                "name": cam.name,
                "thumbnail": thumb_path,
                "frames": segment_frames.get(cam.name),
            })
    finally:
        scene.camera = original_camera
        _set_render_engine(render, original_engine)
        render.resolution_x = original_res_x
        render.resolution_y = original_res_y
        render.resolution_percentage = original_pct
        render.filepath = original_filepath
        _set_image_format(render.image_settings, original_format)

    emit_result({"ok": True, "shots": shots, "fps": fps})


def _blocks_to_render(segments, frame_start, frame_end):
    """Regroupe les segments (voir PageSync.build_segments) en plages de
    frames CONTIGUËS à réellement rendre — en sautant tout segment sans page
    assignée (un plan caméra existant dans le template mais pas encore
    attribué à une page, ex. 2 pages assignées sur les 9 plans possibles).
    apply_frame() n'affiche/anime rien pour ces frames-là (page introuvable
    → sortie immédiate) : les rendre serait du temps perdu, surtout en
    FINAL/Cycles où chaque frame peut coûter plusieurs secondes.

    Deux segments consécutifs (même sans être la même page) sont fusionnés
    dans le même bloc s'ils se suivent sans trou — seul un segment sans page
    (donc sauté) coupe un bloc en deux."""
    blocks = []
    current = None
    for seg_start, seg_end, page_uid in segments:
        if page_uid is None:
            current = None
            continue
        if current is not None and seg_start == current[1] + 1:
            current[1] = seg_end
        else:
            current = [seg_start, seg_end]
            blocks.append(current)

    if not blocks:
        # Filet de sécurité : aucun plan assigné à aucune page (ne devrait
        # pas arriver via le flux normal de l'app) — mieux vaut rendre la
        # plage complète que ne rien rendre du tout.
        return [[frame_start, frame_end]]
    return blocks


def _assemble_blocks_via_vse(block_files, output_base, render):
    """Concatène plusieurs fichiers vidéo bout à bout, via le monteur intégré
    de Blender (Video Sequence Editor) plutôt qu'un outil externe — Blender
    n'embarque pas de binaire ffmpeg autonome sur cette installation
    (bpy.app.binary_path_ffmpeg est vide, vérifié). Chaque bloc devient un
    strip vidéo sur une piste, placés bout à bout dans une scène temporaire
    dédiée, puis toute la timeline résultante est rendue vers le fichier
    final avec les mêmes réglages ffmpeg (format/codec/qualité/résolution
    effective) que les blocs eux-mêmes — recopie donc sans perte de qualité
    supplémentaire au-delà de celle déjà appliquée par blocs."""
    seq_scene = bpy.data.scenes.new("AgenceAssembly")
    try:
        seq_scene.sequence_editor_create()
        seq = seq_scene.sequence_editor
        # `sequence_editor.sequences` → `.strips` en Blender 5.x (constaté
        # le 2026-09-11 avec la 5.2.1 : `'SequenceEditor' object has no
        # attribute 'sequences'`) — `.strips` existe déjà en 4.x (alias
        # introduit avant le renommage complet), donc `hasattr` avec repli
        # sur l'ancien nom suffit à couvrir les 2 versions sans branche
        # explicite par version majeure. `hasattr`, PAS `getattr(...) or
        # ...` : la collection `strips` est VIDE à cet instant (rien
        # ajouté encore), et une collection Blender vide est FAUSSE en
        # contexte booléen (comme une liste Python vide) — `or` serait
        # retombé sur `.sequences` malgré tout, piège réel rencontré ici.
        strips = seq.strips if hasattr(seq, "strips") else seq.sequences
        cursor = 1
        for i, block_file in enumerate(block_files):
            strip = strips.new_movie(
                name="bloc_%d" % i, filepath=block_file, channel=1, frame_start=cursor
            )
            cursor += strip.frame_final_duration

        seq_scene.frame_start = 1
        seq_scene.frame_end = max(1, cursor - 1)
        seq_scene.render.resolution_x = int(render.resolution_x * render.resolution_percentage / 100)
        seq_scene.render.resolution_y = int(render.resolution_y * render.resolution_percentage / 100)
        seq_scene.render.resolution_percentage = 100
        seq_scene.render.fps = render.fps
        seq_scene.render.fps_base = render.fps_base
        _set_image_format(seq_scene.render.image_settings, 'FFMPEG')
        seq_scene.render.ffmpeg.format = render.ffmpeg.format
        seq_scene.render.ffmpeg.codec = render.ffmpeg.codec
        seq_scene.render.ffmpeg.constant_rate_factor = render.ffmpeg.constant_rate_factor
        seq_scene.render.filepath = output_base

        with bpy.context.temp_override(scene=seq_scene):
            bpy.ops.render.render(animation=True, write_still=False)
    finally:
        bpy.data.scenes.remove(seq_scene)


def cmd_render(config):
    """Applique le mode de rendu, installe le handler de synchro par frame,
    et lance le rendu animé — seulement sur les plages de frames dont le
    plan caméra est assigné à une page (voir _blocks_to_render). Écrit aussi
    un PNG d'aperçu à chaque frame terminée pour que l'app puisse afficher
    un rendu 'live'.

    Deux cas :
      - tous les plans du template sont assignés (cas courant), OU un seul
        bloc contigu à rendre : un seul rendu continu direct vers le
        fichier final, comportement d'origine inchangé — Blender pilote
        lui-même la caméra active via les marqueurs natifs ("bind camera to
        markers") en itérant frame_start..frame_end.
      - plusieurs blocs séparés par des plans non assignés : chaque bloc est
        rendu SUR SON VRAI NUMÉRO DE FRAME (scene.frame_start/frame_end =
        les bornes réelles du bloc, aucun axe "virtuel") dans un fichier
        temporaire, puis tous les fichiers sont assemblés bout à bout en un
        seul fichier final (_assemble_blocks_via_vse). Une première version
        tentait de tout rendre en un seul passage sur un axe de frames
        virtuel compact avec la caméra choisie à la main — ABANDONNÉE : elle
        ne mettait à jour que la caméra et la texture, pas le reste de la
        scène (position propre de la caméra, éclairages et matériaux
        animés par plan), qui restait évalué sur le mauvais numéro de frame
        (le virtuel, pas le réel) → caméra figée/désynchronisée et
        éclairages mal activés. Rendre chaque bloc sur son VRAI axe de
        frames élimine ce problème à la racine : tout ce qui est animé dans
        la scène (caméra, lumières, matériaux) est alors évalué exactement
        comme dans un rendu classique."""
    scene = bpy.context.scene
    mode = config["mode"]  # 'TEST' | 'FINAL'

    apply_render_mode_settings(scene, mode)

    # Réglages du projet (color pickers Fond/Tablette côté app) — absents du
    # config si l'utilisateur n'a jamais touché ces réglages, voir
    # RenderConfigBuilder.swift. "Noir basic" = les BOUTONS de l'appareil
    # (bord visible sur la tranche du cadre), demande explicite du
    # 2026-09-07 : "juste les boutons qui changent de couleur, pas tout
    # l'appareil". 2 essais précédents écartés : "Body Apple" (0 face du
    # cadre ne l'utilise réellement, juste un slot inutilisé) et
    # "Material" (indiqué par l'utilisateur, mais sans effet visible
    # confirmé par rendu — testé isolément à la place, "Noir basic" donne
    # bien le changement visible attendu).
    apply_color_override(["Fond"], config.get("background_color_hex"))
    apply_color_override(["Noir basic"], config.get("device_color_hex"))

    render_dir = config["render_dir"]
    os.makedirs(render_dir, exist_ok=True)
    output_base = os.path.join(render_dir, config["output_name"])

    fps = scene.render.fps / scene.render.fps_base if scene.render.fps_base else scene.render.fps
    sync = PageSync(config, fps)
    full_start, full_end = scene.frame_start, scene.frame_end
    # Construit les segments AVANT d'enregistrer le handler frame_change_pre
    # — build_segments ne bouge pas la frame courante, mais autant garder
    # l'ordre explicite : calcul d'abord, écoute des changements ensuite.
    segments = sync.build_segments(scene, full_start, full_end)
    blocks = _blocks_to_render(segments, full_start, full_end)
    total_frames = sum(end - start + 1 for start, end in blocks)

    def frame_handler(scene_arg, depsgraph=None):
        # scene_arg peut être la scène d'assemblage VSE si ce handler est
        # encore enregistré pendant cette passe-là (jamais le cas ici, il
        # est retiré avant, mais gardé par prudence/lisibilité) — pas de
        # synchro de page/texture à faire sur une scène sans caméra 3D.
        if scene_arg is not scene:
            return
        try:
            sync.apply_frame(scene_arg, segments)
        except Exception as exc:
            print("AGENCE_WARN sync frame: %s" % exc)

    bpy.app.handlers.frame_change_pre.append(frame_handler)

    # Aperçu live : un PNG écrit après chaque frame rendue. Écriture dans un
    # fichier temporaire puis os.replace pour que l'app ne lise jamais un
    # fichier à moitié écrit. Compteur virtuel (rendered_count) envoyé à
    # l'app pour sa barre de progression/ETA — voir PROGRESS_RE côté
    # app/core/blender.py : contrairement au numéro de frame Blender natif,
    # il avance toujours de 1 en 1, jamais par bond, même quand des plans
    # non assignés sont sautés (et même entre deux blocs distincts).
    preview_path = config.get("preview_path")
    rendered_count = 0

    def render_post_handler(scene_arg, depsgraph=None):
        if scene_arg is not scene:
            return
        nonlocal rendered_count
        rendered_count += 1
        print("AGENCE_PROGRESS %d %d %d" % (scene_arg.frame_current, rendered_count, total_frames))
        if preview_path:
            try:
                result = bpy.data.images.get("Render Result")
                if result is not None:
                    tmp_path = preview_path + ".tmp.png"
                    result.save_render(filepath=tmp_path)
                    os.replace(tmp_path, preview_path)
                    print("AGENCE_PREVIEW %d" % scene_arg.frame_current)
            except Exception as exc:
                print("AGENCE_WARN preview: %s" % exc)
        sys.stdout.flush()

    bpy.app.handlers.render_post.append(render_post_handler)

    emit_result({
        "ok": True,
        "stage": "render_start",
        "frame_start": 1,
        "frame_end": total_frames,
    })

    single_full_block = (
        len(blocks) == 1 and blocks[0][0] == full_start and blocks[0][1] == full_end
    )

    if single_full_block:
        scene.frame_set(full_start)
        sync.apply_frame(scene, segments)
        scene.render.filepath = output_base
        bpy.ops.render.render(animation=True, write_still=False)
    else:
        temp_dir = os.path.join(render_dir, ".agence_render_blocks")
        os.makedirs(temp_dir, exist_ok=True)
        block_files = []
        try:
            for i, (start, end) in enumerate(blocks):
                scene.frame_start, scene.frame_end = start, end
                scene.frame_set(start)
                sync.apply_frame(scene, segments)
                block_base = os.path.join(temp_dir, "bloc_%03d_" % i)
                scene.render.filepath = block_base
                bpy.ops.render.render(animation=True, write_still=False)
                matches = sorted(glob.glob(block_base + "*"))
                if not matches:
                    raise RuntimeError(
                        "Segment de rendu introuvable après le bloc %d (frames %d-%d)" % (i, start, end)
                    )
                block_files.append(matches[0])

            # Retirés avant l'assemblage : plus rien à synchroniser (piste
            # vidéo pure) et la progression de CE passage-là ne doit pas
            # s'ajouter à celle déjà comptée frame par frame ci-dessus.
            bpy.app.handlers.frame_change_pre.remove(frame_handler)
            bpy.app.handlers.render_post.remove(render_post_handler)
            _assemble_blocks_via_vse(block_files, output_base, scene.render)
        finally:
            for block_file in block_files:
                try:
                    os.remove(block_file)
                except OSError:
                    pass
            try:
                os.rmdir(temp_dir)
            except OSError:
                pass

    emit_result({"ok": True, "stage": "render_done"})


def cmd_color_preview(config):
    """Rend UN seul still avec les dérogations de couleur (Fond/Tablette,
    réglages avancés) appliquées — bouton "Aperçu" à côté des color
    pickers côté app (2026-09-07). Réglages TEST (rapide, EEVEE) : ce
    n'est qu'un aperçu, pas un livrable. `camera`/`desktop_path`/
    `mobile_path` optionnels — sans capture existante, on prévisualise
    quand même les couleurs sur l'écran tel qu'il était déjà dans le
    .blend plutôt que d'échouer."""
    scene = bpy.context.scene
    apply_render_mode_settings(scene, 'TEST')

    apply_color_override(["Fond"], config.get("background_color_hex"))
    apply_color_override(["Noir basic"], config.get("device_color_hex"))

    camera_name = config.get("camera")
    cam = bpy.data.objects.get(camera_name) if camera_name else None
    if cam is not None:
        scene.camera = cam

    # Frame fixe (demande explicite du 2026-09-07) : la caméra choisie
    # peut être animée (voir le cas "Plan 2 - Desktop", keyframée entre
    # ses frames 100 et 190) — figer sur 100 donne un cadrage stable et
    # reproductible d'un aperçu couleur à l'autre, peu importe où en était
    # la timeline au dernier enregistrement du .blend.
    scene.frame_set(100)

    node_desktop = find_image_node(NOM_MATERIAL, NOM_NOEUD_DESKTOP)
    node_mobile = find_image_node(NOM_MATERIAL, NOM_NOEUD_MOBILE)
    desktop_path = config.get("desktop_path")
    mobile_path = config.get("mobile_path")
    # `sync_texture_node` détecte lui-même image fixe vs séquence animée
    # (voir son commentaire) — pour cet aperçu figé, on affiche toujours
    # la PREMIÈRE frame (fraction 0.0, haut de page).
    if desktop_path:
        ok, frame_count = sync_texture_node(node_desktop, desktop_path, DESKTOP_HEIGHT, DESKTOP_WIDTH)
        if ok:
            if frame_count > 0:
                apply_sequence_frame(node_desktop, 0.0, frame_count, scene.frame_current)
            else:
                apply_scroll_position(node_desktop, 0.0)
    if mobile_path:
        ok, frame_count = sync_texture_node(node_mobile, mobile_path, MOBILE_HEIGHT, MOBILE_WIDTH)
        if ok:
            if frame_count > 0:
                apply_sequence_frame(node_mobile, 0.0, frame_count, scene.frame_current)
            else:
                apply_scroll_position(node_mobile, 0.0)

    output_path = config["output_path"]
    scene.render.filepath = output_path
    _set_image_format(scene.render.image_settings, 'PNG')
    bpy.ops.render.render(write_still=True)

    emit_result({"ok": True, "path": output_path})


COMMANDS = {
    "list_shots": cmd_list_shots,
    "render": cmd_render,
    "color_preview": cmd_color_preview,
}


def main():
    try:
        argv = sys.argv[sys.argv.index("--") + 1:]
    except ValueError:
        argv = []

    if not argv:
        emit_result({"ok": False, "error": "Aucune commande fournie après --"})
        sys.exit(1)

    command = argv[0]
    config = {}
    if len(argv) > 1 and argv[1]:
        with open(argv[1], "r", encoding="utf-8") as f:
            config = json.load(f)

    handler = COMMANDS.get(command)
    if handler is None:
        emit_result({"ok": False, "error": "Commande inconnue : %s" % command})
        sys.exit(1)

    try:
        handler(config)
    except Exception as exc:
        import traceback
        traceback.print_exc()
        emit_result({"ok": False, "error": str(exc)})
        sys.exit(1)


main()
