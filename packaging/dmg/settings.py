# dmgbuild settings for VoiceBud.dmg (packaging/build-dmg.sh passes app, background and volume name)
app = defines["app"]
files = [app]
symlinks = {"Programme": "/Applications"}
# no hide_extensions: it sets Finder info on the app, and a signed app with Finder info fails the
# strict signature check (recipients could see "damaged" instead of "Open Anyway"); Finder hides
# ".app" on its own
icon_locations = {"VoiceBud.app": (170, 158), "Programme": (470, 158)}
background = defines["background"]
# the window height counts the 32 pt titlebar (macOS 26): 432 leaves the full 400 pt for the background
window_rect = ((240, 160), (640, 432))
default_view = "icon-view"
icon_size = 112
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
format = "UDRW"          # build-dmg.sh hides the background file, then compresses
filesystem = "HFS+"
