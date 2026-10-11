class_name PyRandom
extends RefCounted
## Exakter Nachbau von CPythons random.Random (MT19937 + Python-Algorithmen).
##
## Gleicher Seed => gleiche Zahlenfolge wie im Python-Original. Damit erzeugt der
## Port dieselben Straßen, Passanten und Replikanten wie die Desktop-Version, und
## beide lassen sich Bild für Bild vergleichen. Getestet gegen Python 3.14
## (tests/test_pyrandom.gd).

const N := 624
const M := 397
const MATRIX_A := 0x9908b0df
const UPPER := 0x80000000
const LOWER := 0x7fffffff
const MASK32 := 0xFFFFFFFF
const TWOPI := 6.283185307179586

var mt := PackedInt64Array()
var mti := N + 1
var gauss_next: Variant = null


func _init(seed_value: int = 0) -> void:
	reseed(seed_value)


func reseed(a: int) -> void:
	var n := a if a >= 0 else -a
	var key := PackedInt64Array()
	if n == 0:
		key.append(0)
	else:
		while n > 0:
			key.append(n & MASK32)
			n = n >> 32
	_init_by_array(key)
	gauss_next = null


func _init_genrand(s: int) -> void:
	mt.resize(N)
	mt[0] = s & MASK32
	for i in range(1, N):
		var prev := mt[i - 1]
		mt[i] = (1812433253 * (prev ^ (prev >> 30)) + i) & MASK32
	mti = N


func _init_by_array(key: PackedInt64Array) -> void:
	_init_genrand(19650218)
	var i := 1
	var j := 0
	var kl := key.size()
	var k := maxi(N, kl)
	while k > 0:
		var prev := mt[i - 1]
		mt[i] = ((mt[i] ^ (((prev ^ (prev >> 30)) * 1664525) & MASK32)) + key[j] + j) & MASK32
		i += 1
		j += 1
		if i >= N:
			mt[0] = mt[N - 1]
			i = 1
		if j >= kl:
			j = 0
		k -= 1
	k = N - 1
	while k > 0:
		var prev := mt[i - 1]
		mt[i] = ((mt[i] ^ (((prev ^ (prev >> 30)) * 1566083941) & MASK32)) - i) & MASK32
		i += 1
		if i >= N:
			mt[0] = mt[N - 1]
			i = 1
		k -= 1
	mt[0] = 0x80000000


func genrand_uint32() -> int:
	var y: int
	if mti >= N:
		var kk := 0
		while kk < N - M:
			y = (mt[kk] & UPPER) | (mt[kk + 1] & LOWER)
			mt[kk] = mt[kk + M] ^ (y >> 1) ^ (MATRIX_A if (y & 1) else 0)
			kk += 1
		while kk < N - 1:
			y = (mt[kk] & UPPER) | (mt[kk + 1] & LOWER)
			mt[kk] = mt[kk + (M - N)] ^ (y >> 1) ^ (MATRIX_A if (y & 1) else 0)
			kk += 1
		y = (mt[N - 1] & UPPER) | (mt[0] & LOWER)
		mt[N - 1] = mt[M - 1] ^ (y >> 1) ^ (MATRIX_A if (y & 1) else 0)
		mti = 0
	y = mt[mti]
	mti += 1
	y ^= (y >> 11)
	y ^= (y << 7) & 0x9d2c5680
	y ^= (y << 15) & 0xefc60000
	y ^= (y >> 18)
	return y & MASK32


## random() -> float in [0, 1) mit 53 Bit, wie CPython.
func random() -> float:
	var a := genrand_uint32() >> 5
	var b := genrand_uint32() >> 6
	return (float(a) * 67108864.0 + float(b)) * (1.0 / 9007199254740992.0)


func getrandbits(k: int) -> int:
	if k <= 0:
		return 0
	if k <= 32:
		return genrand_uint32() >> (32 - k)
	# bis 63 Bit: Wörter little-endian
	var r := 0
	var shift := 0
	var rem := k
	while rem > 0:
		var w := genrand_uint32()
		if rem < 32:
			w = w >> (32 - rem)
		r |= w << shift
		shift += 32
		rem -= 32
	return r


static func _bit_length(n: int) -> int:
	var b := 0
	while n > 0:
		b += 1
		n = n >> 1
	return b


func _randbelow(n: int) -> int:
	var k := _bit_length(n)
	var r := getrandbits(k)
	while r >= n:
		r = getrandbits(k)
	return r


func randrange(start: int, stop: Variant = null, step: int = 1) -> int:
	if stop == null:
		assert(start > 0, "empty range for randrange()")
		return _randbelow(start)
	var width: int = int(stop) - start
	if step == 1:
		assert(width > 0, "empty range in randrange")
		return start + _randbelow(width)
	var n := 0
	if step > 0:
		n = floori(float(width + step - 1) / float(step))
	else:
		n = floori(float(width + step + 1) / float(step))
	assert(n > 0, "empty range in randrange")
	return start + step * _randbelow(n)


func randint(a: int, b: int) -> int:
	return a + _randbelow(b - a + 1)


func uniform(a: float, b: float) -> float:
	return a + (b - a) * random()


func choice(seq: Variant) -> Variant:
	var n: int = seq.size()
	assert(n > 0, "Cannot choose from an empty sequence")
	return seq[_randbelow(n)]


## choices(population, weights) mit k=1 -> ein Element (häufigster Fall im Spiel).
func choices1(population: Array, weights: Variant = null) -> Variant:
	var n := population.size()
	if weights == null:
		return population[floori(random() * float(n))]
	var cum := []
	var acc := 0.0
	for w in weights:
		acc += float(w)
		cum.append(acc)
	var total: float = cum[cum.size() - 1]
	var x := random() * total
	# bisect_right(cum, x, 0, n-1)
	var lo := 0
	var hi := n - 1
	while lo < hi:
		var mid := (lo + hi) >> 1
		if x < float(cum[mid]):
			hi = mid
		else:
			lo = mid + 1
	return population[lo]


## choices(population, weights, k=k) -> Array
func choices(population: Array, weights: Variant = null, k: int = 1) -> Array:
	var out := []
	for _i in k:
		out.append(choices1(population, weights))
	return out


func shuffle(x: Array) -> void:
	var i := x.size() - 1
	while i >= 1:
		var j := _randbelow(i + 1)
		var tmp: Variant = x[i]
		x[i] = x[j]
		x[j] = tmp
		i -= 1


func sample(population: Array, k: int) -> Array:
	var n := population.size()
	assert(k >= 0 and k <= n, "Sample larger than population or is negative")
	var result := []
	result.resize(k)
	var setsize := 21
	if k > 5:
		setsize += int(pow(4.0, ceil(log(float(k * 3)) / log(4.0))))
	if n <= setsize:
		var pool := population.duplicate()
		for i in k:
			var j := _randbelow(n - i)
			result[i] = pool[j]
			pool[j] = pool[n - i - 1]
	else:
		var selected := {}
		for i in k:
			var j := _randbelow(n)
			while selected.has(j):
				j = _randbelow(n)
			selected[j] = true
			result[i] = population[j]
	return result


func gauss(mu: float = 0.0, sigma: float = 1.0) -> float:
	var z: Variant = gauss_next
	gauss_next = null
	if z == null:
		var x2pi := random() * TWOPI
		var g2rad := sqrt(-2.0 * log(1.0 - random()))
		z = cos(x2pi) * g2rad
		gauss_next = sin(x2pi) * g2rad
	return mu + float(z) * sigma
