#!/bin/bash
# Warnungen = Fehler: Kopie des Projekts mit tools/warnings_override.cfg, dann jedes
# Skript unter src/ und tests/ laden. Meldet jede Warnung mit Datei:Zeile (diffbar
# gegen einen Stand ohne die eigenen Änderungen).
#   tools/check_warnings_all.sh [<quellbaum>]     (Default: dieser Worktree)
T=/home/alex/.local/opt/shadegunner-tools
W=${1:-$(cd "$(dirname "$0")/.." && pwd)}
S=$T/scratch_warn_$(basename "$W")
export XDG_DATA_HOME=$T/godotdata XDG_CONFIG_HOME=$T/godotconfig
rsync -a --delete --exclude .godot --exclude .git --exclude shots "$W/" "$S/"
cp "$W/tools/warnings_override.cfg" "$S/override.cfg"
mkdir -p "$S/.warncheck" && touch "$S/.warncheck/.gdignore"
cat > "$S/.warncheck/check.gd" <<'EOF'
extends SceneTree
func _init() -> void:
	var files: Array = []
	for d in ["res://src", "res://tests"]:
		_walk(d, files)
	var bad := 0
	for f: String in files:
		var s: GDScript = load(f)
		if s == null or not s.can_instantiate():
			print("FEHLER ", f)
			bad += 1
	print("warncheck: %d Dateien, %d fehlerhaft" % [files.size(), bad])
	quit(bad)
func _walk(d: String, out: Array) -> void:
	for f in DirAccess.get_files_at(d):
		if f.ends_with(".gd"):
			out.append(d.path_join(f))
	for sd in DirAccess.get_directories_at(d):
		_walk(d.path_join(sd), out)
EOF
timeout 300 $T/bin/godot --headless --path "$S" --import >/dev/null 2>&1
timeout 300 $T/bin/godot --headless --path "$S" --script "$S/.warncheck/check.gd" 2>&1 \
  | grep -A1 "Parse Error" | paste - - - 2>/dev/null | grep -o "Parse Error: .*(Warning treated as error.).*res://[^)]*" \
  | sed -E 's/\s+at: GDScript::reload / @ /' | sort -u
