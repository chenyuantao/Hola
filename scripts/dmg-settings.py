"""Finder layout for the drag-to-Applications release disk image."""

import os

app = os.environ["HOLA_DMG_APP"]
background = os.environ["HOLA_DMG_BACKGROUND"]

files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

format = "UDZO"
filesystem = "HFS+"
background = background
window_rect = ((120, 120), (760, 560))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
icon_size = 112
text_size = 15
icon_locations = {"Hola.app": (180, 440), "Applications": (580, 440)}
