class_name I18n
extends RefCounted
## Deutsch/Englisch wie shadegunner/i18n.py. Schlüssel = deutscher Text.
##   I18n.t("TEXT")                        -> übersetzt
##   I18n.t("BESTWERT {:06d}", [score])   -> übersetzt + formatiert (Py.fmt)

static var lang := "de"


static func get_lang() -> String:
	return lang


static func set_lang(l: String) -> void:
	lang = "en" if l == "en" else "de"


static func t(s: String, args: Array = [], kw: Dictionary = {}) -> String:
	var txt := s if lang == "de" else String(DI18n.TR.get(s, s))
	if not args.is_empty() or not kw.is_empty():
		txt = Py.fmt(txt, args, kw)
	return txt


static func lang_name(l: String) -> String:
	return "ENGLISH" if l == "en" else "DEUTSCH"
