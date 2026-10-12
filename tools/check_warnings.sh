#!/bin/bash
# Warnungsprüfung der HUD-Port-Dateien in einer Kopie (Kern-Warnungen dort unterdrückt)
T=/home/alex/.local/opt/shadegunner-tools
S=$T/scratch_hud
export XDG_DATA_HOME=$T/godotdata XDG_CONFIG_HOME=$T/godotconfig
rsync -a --delete --exclude .godot --exclude .git --exclude shots $T/wt/hud/ $S/
cp $T/wt/hud/tools/warnings_override.cfg $S/override.cfg
for f in $S/src/core/*.gd $S/src/data/*.gd $S/src/config.gd $S/src/persp.gd $S/src/render/crt_chain.gd; do
  sed -i '0,/^extends.*$/s//&\n@warning_ignore_start("integer_division", "int_as_enum_without_cast", "shadowed_global_identifier", "narrowing_conversion", "unused_parameter", "unused_variable", "shadowed_variable", "incompatible_ternary", "unused_private_class_variable", "confusable_identifier", "static_called_on_instance", "unassigned_variable", "standalone_expression")/' $f
done
[ -d $S/.godot ] || timeout 300 $T/bin/godot --headless --path $S --import >/dev/null 2>&1
timeout 120 $T/bin/godot --headless --path $S --script res://tests/compile_check.gd 2>&1 | grep -A1 "Parse Error\|compile_check" | grep -v "^--"
