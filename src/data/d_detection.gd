class_name DDetection
extends RefCounted
## AUTOMATISCH ERZEUGT aus shadegunner.detection (tools/export_data.py) - nicht von Hand ändern.

const ORDER = ["gait", "anachron", "pupils", "stimulus", "serial"]
const PRIOR = 0.3
const STRONG_TELLS = ["pupils", "stimulus", "serial"]
const TELLS = {
	"pupils": [0.6, 0.05, true, "PUPILLE"],
	"stimulus": [0.55, 0.06, true, "REIZ"],
	"serial": [0.7, 0.01, true, "SERIE"],
	"gait": [0.45, 0.1, false, "GANG"],
	"anachron": [0.35, 0.07, false, "DETAIL"],
}
const WEAK_TELLS = ["gait", "anachron"]
