"""Frames whatever is in the scene and switches the viewport to Material Preview.

Companion to opening a prepared .blend:

    blender build/wolf_preview.blend --python tools/blender/frame_view.py

Kept separate from any importing on purpose. Blender's glTF importer dereferences
`bpy.context.object`, which does not exist when a script runs against an empty
scene at startup, so importing from inside the GUI fails with a confusing
AttributeError raised from inside the addon. The fix is to import headlessly into
the default scene (which has an active object), save a .blend, and let the GUI do
nothing but look at it. This script therefore only touches the viewport.
"""

import bpy


def _frame() -> float | None:
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type != "VIEW_3D":
                continue
            for space in area.spaces:
                if space.type == "VIEW_3D":
                    space.shading.type = "MATERIAL"
                    space.clip_end = 500.0
                    space.overlay.show_floor = True
            region = next((r for r in area.regions if r.type == "WINDOW"), None)
            if region is not None:
                with bpy.context.temp_override(window=window, area=area, region=region):
                    bpy.ops.object.select_all(action="SELECT")
                    bpy.ops.view3d.view_all(center=True)
                    bpy.ops.object.select_all(action="DESELECT")
    print("FRAMED")
    return None


bpy.app.timers.register(_frame, first_interval=0.6)
