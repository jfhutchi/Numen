"""Opens the CC0 wolf in the Blender GUI, framed and ready to play.

    blender --python tools/blender/view_wolf.py

Deliberately not --factory-startup, so your own theme and keymap are kept; the
scene is emptied instead. The viewport is switched to Material Preview, the
Walk action is made active and the frame range set to it, so pressing Space
plays the walk cycle straight away.
"""

import os

import bpy

WOLF = os.path.abspath(
    os.path.join("assets", "third_party", "quaternius", "ultimate-animated-animals", "wolf.glb")
)
PREFERRED_CLIP = "Walk"


def _report_scale() -> None:
    """Prints the imported size, which is what the Godot side needs to scale by."""
    for obj in bpy.data.objects:
        if obj.type == "MESH":
            d = obj.dimensions
            print("WOLF_MESH %s dims=%.3f x %.3f x %.3f" % (obj.name, d.x, d.y, d.z))
    print("WOLF_ACTIONS %d" % len(bpy.data.actions))
    for action in sorted(bpy.data.actions, key=lambda a: a.name):
        start, end = action.frame_range
        print("  clip %-28s frames %.0f-%.0f" % (action.name, start, end))


def _activate_walk() -> None:
    armature = next((o for o in bpy.data.objects if o.type == "ARMATURE"), None)
    if armature is None:
        return
    action = None
    for candidate in bpy.data.actions:
        # Clip names arrive either bare or prefixed with the armature name.
        if candidate.name.split("|")[-1] == PREFERRED_CLIP:
            action = candidate
            break
    if action is None:
        return
    if armature.animation_data is None:
        armature.animation_data_create()
    armature.animation_data.action = action
    start, end = action.frame_range
    bpy.context.scene.frame_start = int(start)
    bpy.context.scene.frame_end = int(end)
    bpy.context.scene.frame_set(int(start))
    print("WOLF_PLAYING %s (%d-%d)" % (action.name, start, end))


def _dress_viewport() -> float | None:
    """Runs once the window exists; returns None to unregister the timer."""
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type != "VIEW_3D":
                continue
            for space in area.spaces:
                if space.type == "VIEW_3D":
                    space.shading.type = "MATERIAL"
                    space.clip_end = 500.0
            region = next((r for r in area.regions if r.type == "WINDOW"), None)
            if region is not None:
                with bpy.context.temp_override(window=window, area=area, region=region):
                    bpy.ops.view3d.view_all(center=True)
    return None


def _load() -> float | None:
    """Does all the work, deferred until the window exists.

    Nothing here can run at `--python` startup time. Blender's own glTF importer
    reaches for `bpy.context.object` while building the armature display, and that
    attribute only exists once a real window context is up — importing directly
    from module scope dies with `'Context' object has no attribute 'object'`
    inside the addon, which looks like a broken file rather than a timing problem.
    """
    bpy.ops.wm.read_homefile(use_empty=True)
    if not os.path.exists(WOLF):
        print("WOLF_MISSING %s" % WOLF)
        return None

    bpy.ops.import_scene.gltf(filepath=WOLF)
    _report_scale()
    _activate_walk()
    bpy.ops.object.select_all(action="DESELECT")
    _dress_viewport()
    return None


bpy.app.timers.register(_load, first_interval=0.5)
