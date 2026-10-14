class_name Actor
extends RefCounted
## Aktoren der Spielwelt: Spieler, Passanten, Replikanten (entities.py).
##
## Reine Daten. Verhalten (KI, Animation, Kampf) lebt in World.
## Python-set `revealed` ist hier ein Dictionary {name: true} ("x" in revealed geht gleich).

var x: float = 0.0
var depth: float = 0.5                 # 0 = hinten (Bordstein), 1 = nah (Kamera)
var look: Dictionary = {}
var uid: int = 0

var is_replicant: bool = false
var player: bool = false
var alive: bool = true
var dead_t: float = 0.0                # Sekunden seit Tod (Animation, Blutlache)
var escaped: bool = false

var facing: int = 1
var speed: float = 20.0                # bevorzugte Gehgeschwindigkeit
var vx: float = 0.0
var vd: float = 0.0
var target_depth: float = 0.5

# Verhalten: walk | idle | loiter | panic | flee | attack | cower | duck | freeze | hands | hurt | dead
#            Spieler: idle | walk | run | aim | shoot | scan | hurt | dead
var state: String = "walk"
var state_t: float = 0.0
var timer: float = 0.0                 # Restzeit des aktuellen Zustands
var anim: String = "walk"
var phase: float = 0.0                 # Animationsphase 0..1 (zyklisch)
var frame: int = 0
var hit_done: bool = true

# Tells: name -> bool (vorhanden). `revealed` = bereits aufgedeckt (Set als Dictionary).
var tells: Dictionary = {}
var revealed: Dictionary = {}
var scanned: bool = false
var exposure: float = 0.0
var alert: bool = false                # Replikant weiß, dass er erkannt wurde
var aggressive: bool = false
var aimed_t: float = 0.0               # wie lange der Spieler schon auf ihn zielt

var glint_t: float = 0.0               # Restzeit Augenreflex
var glint_next: float = 5.0
var flash_t: float = 0.0               # Treffer-Blitz
var knock: float = 0.0                 # Rückstoß-Geschwindigkeit
var hp: int = 1
var invuln: float = 0.0
var attack_cd: float = 0.0

var boss: bool = false                 # Endboss (ROY)
var boss_invuln: bool = false
var peaceful: bool = false             # stirbt von selbst (ROY): keine Kreide, keine Lache

var z: float = 0.0                     # Sprunghöhe (Welt-Einheiten)
var vz: float = 0.0
var dodge_t: float = 0.0               # weicht gerade Verkehr aus (schnelle Tiefenbewegung)
var lit_t: float = 0.0                 # Sekunden im Suchlicht
var bounty: bool = false               # Kopfgeld-Ziel der Zone
var name: String = ""
var group: int = -1                    # Gruppe, die zusammen herumsteht (-1 = allein)
var home: Variant = null               # bevorzugtes Tiefenband [lo, hi], z. B. hinterer Gehweg
var gx: float = 0.0                    # Gruppenmitte (x), der Blick geht dorthin
var react_t: float = 0.0               # Reaktionslatenz (Schreck, Alter)


## Actor.new(x, depth, {feld: wert, ...}) - wie der dataclass-Konstruktor mit Schlüsselwörtern.
func _init(x_: float = 0.0, depth_: float = 0.5, kw: Dictionary = {}) -> void:
	x = x_
	depth = depth_
	for k: String in kw:
		set(k, kw[k])
