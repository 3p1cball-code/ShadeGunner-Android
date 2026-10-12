class_name _Spot
extends RefCounted
## Floater-Anker ohne Figur (z. B. der Koch am Nudelstand).

var uid: int = 0
var x: float = 0.0
var depth: float = 0.0


func _init(uid_: int = 0, x_: float = 0.0, depth_: float = 0.0) -> void:
	uid = uid_
	x = x_
	depth = depth_
