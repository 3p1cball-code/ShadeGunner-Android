class_name Assets
extends RefCounted
## Mitgelieferte Bilder (assets.py): Spiel-Icons unter res://assets/icons/.
## Fehlen sie, läuft das Spiel ohne (emblem liefert null).

const ICON_SIZES := [16, 24, 32, 48, 64, 128, 256, 512]

static var _CACHE: Dictionary = {}


static func icon_path(size: int) -> Variant:
	var f := "res://assets/icons/shadegunner-%d.png" % size
	if ResourceLoader.exists(f) or FileAccess.file_exists(f):
		return f
	return null


## Emblem als QImg (premultipliziert, nearest um `scale` vergrößert, gecacht) oder null.
static func emblem(size: int, scale: int = 1) -> QImg:
	var key := "%d:%d" % [size, scale]
	if not _CACHE.has(key):
		var img: QImg = null
		var f: Variant = icon_path(size)
		if f != null:
			var im: Image = null
			var tx: Variant = load(f) if ResourceLoader.exists(f) else null
			if tx is Texture2D:
				im = (tx as Texture2D).get_image()
			else:
				im = Image.load_from_file(f)
			if im != null and not im.is_empty():
				if im.is_compressed():
					im.decompress()
				im.convert(Image.FORMAT_RGBA8)
				im.premultiply_alpha()
				if scale != 1:
					im.resize(size * scale, size * scale, Image.INTERPOLATE_NEAREST)
				img = QImg.new(ImageTexture.create_from_image(im))
		_CACHE[key] = img
	return _CACHE[key]
