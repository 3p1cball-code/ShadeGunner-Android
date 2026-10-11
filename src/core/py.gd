class_name Py
extends RefCounted
## Python-Semantik, wo GDScript abweicht. Beim Portieren IMMER diese nehmen:
##
##   Python              GDScript (falsch)        richtig
##   round(x)            round(x)  (2.5 -> 3)     Py.round(x)      (2.5 -> 2, Banker's)
##   round(x, n)         snappedf                 Py.round_n(x, n)
##   a // b              int(a / b)               Py.floordiv(a, b)   (Richtung -inf)
##   a % b  (negativ)    a % b / fmod             Py.mod(a, b)        (Vorzeichen von b)
##   "{:06d}".format(x)  -                        Py.fmt("{:06d}", [x])
##   int(x)              int(x)                   gleich (Richtung 0)


static func round(x: float) -> int:
	var f := floorf(x)
	var d := x - f
	if d > 0.5:
		return int(f) + 1
	if d < 0.5:
		return int(f)
	return int(f) if int(f) % 2 == 0 else int(f) + 1


static func round_n(x: float, n: int) -> float:
	var m := pow(10.0, n)
	return float(Py.round(x * m)) / m


static func floordiv(a: float, b: float) -> float:
	return floorf(a / b)


static func ifloordiv(a: int, b: int) -> int:
	return floori(float(a) / float(b)) if (a < 0) != (b < 0) and a % b != 0 else a / b


static func mod(a: float, b: float) -> float:
	var r := fmod(a, b)
	if r != 0.0 and (r < 0.0) != (b < 0.0):
		r += b
	return r


static func imod(a: int, b: int) -> int:
	var r := a % b
	if r != 0 and (r < 0) != (b < 0):
		r += b
	return r


## Teilmenge von str.format: {} {0} {name} mit Format [[fill]align][sign][0][width][.prec][type]
static func fmt(template: String, args: Array = [], kw: Dictionary = {}) -> String:
	var out := ""
	var i := 0
	var auto := 0
	var n := template.length()
	while i < n:
		var ch := template[i]
		if ch == "{":
			if i + 1 < n and template[i + 1] == "{":
				out += "{"
				i += 2
				continue
			var j := template.find("}", i)
			if j < 0:
				out += template.substr(i)
				break
			var field := template.substr(i + 1, j - i - 1)
			var spec := ""
			var c := field.find(":")
			if c >= 0:
				spec = field.substr(c + 1)
				field = field.substr(0, c)
			var val: Variant
			if field == "":
				val = args[auto] if auto < args.size() else ""
				auto += 1
			elif field.is_valid_int():
				var k := int(field)
				val = args[k] if k < args.size() else ""
			else:
				val = kw.get(field, "")
			out += _spec(val, spec)
			i = j + 1
		elif ch == "}" and i + 1 < n and template[i + 1] == "}":
			out += "}"
			i += 2
		else:
			out += ch
			i += 1
	return out


static func _spec(val: Variant, spec: String) -> String:
	if spec == "":
		if val is float and floorf(val) == val and absf(val) < 1e16:
			return str(val) if str(val).contains(".") else str(val) + ".0"
		return str(val)
	var fill := " "
	var align := ""
	var k := 0
	if spec.length() >= 2 and spec[1] in ["<", ">", "^", "="]:
		fill = spec[0]
		align = spec[1]
		k = 2
	elif spec.length() >= 1 and spec[0] in ["<", ">", "^", "="]:
		align = spec[0]
		k = 1
	var sign := ""
	if k < spec.length() and spec[k] in ["+", "-", " "]:
		sign = spec[k]
		k += 1
	var zero := false
	if k < spec.length() and spec[k] == "0":
		zero = true
		k += 1
	var wstr := ""
	while k < spec.length() and spec[k].is_valid_int():
		wstr += spec[k]
		k += 1
	var width := int(wstr) if wstr != "" else 0
	var prec := -1
	if k < spec.length() and spec[k] == ".":
		k += 1
		var pstr := ""
		while k < spec.length() and spec[k].is_valid_int():
			pstr += spec[k]
			k += 1
		prec = int(pstr)
	var typ := spec.substr(k)
	var body := ""
	var neg := false
	match typ:
		"d":
			var iv := int(val)
			neg = iv < 0
			body = str(absi(iv))
		"f", "%":
			var fv := float(val) * (100.0 if typ == "%" else 1.0)
			neg = fv < 0.0
			body = String.num(absf(fv), prec if prec >= 0 else 6)
			if prec == 0:
				body = str(Py.round(absf(fv)))
			elif prec > 0 and not body.contains("."):
				body += "." + "0".repeat(prec)
			elif prec > 0:
				var dot := body.find(".")
				var have := body.length() - dot - 1
				if have < prec:
					body += "0".repeat(prec - have)
			if typ == "%":
				body += "%"
		"x":
			body = "%x" % int(val)
		_:
			body = str(val)
			if prec >= 0:
				body = body.substr(0, prec)
	var sgn := ""
	if typ in ["d", "f", "%"]:
		if neg:
			sgn = "-"
		elif sign == "+":
			sgn = "+"
		elif sign == " ":
			sgn = " "
	if zero and align == "":
		var pad := width - sgn.length() - body.length()
		if pad > 0:
			body = "0".repeat(pad) + body
		return sgn + body
	var s := sgn + body
	var padn := width - s.length()
	if padn <= 0:
		return s
	if align == "":
		align = ">" if typ in ["d", "f", "%"] or (val is int or val is float) else "<"
	match align:
		"<":
			return s + fill.repeat(padn)
		"^":
			var l := padn / 2
			return fill.repeat(l) + s + fill.repeat(padn - l)
		_:
			return fill.repeat(padn) + s
