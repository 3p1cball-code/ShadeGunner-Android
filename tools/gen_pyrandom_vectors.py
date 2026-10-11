"""Testvektoren für src/core/pyrandom.gd aus echtem CPython erzeugen."""
import json, random, sys
out = []
for seed in [0, 1, 5, 42, 977, 123456789, 2**40 + 7, -3, 65535 * 977 + 31 * 4 + 5]:
    r = random.Random(seed)
    rec = {"seed": seed, "u32": [r.getrandbits(32) for _ in range(5)]}
    r = random.Random(seed)
    rec["random"] = [r.random() for _ in range(5)]
    rec["randint"] = [r.randint(0, 10) for _ in range(6)] + [r.randint(-50, 50) for _ in range(3)]
    rec["uniform"] = [r.uniform(-2.0, 3.0) for _ in range(4)]
    rec["choice"] = [r.choice(list(range(7))) for _ in range(6)]
    rec["randrange"] = [r.randrange(1 << 16) for _ in range(3)] + [r.randrange(3, 40) for _ in range(3)]
    rec["choices"] = [r.choices(["a", "b", "c", "d"], [5, 1, 3, 1])[0] for _ in range(6)]
    rec["choices_nw"] = [r.choices([10, 20, 30])[0] for _ in range(3)]
    rec["sample_small"] = r.sample(range(20), 5)
    rec["sample_big"] = r.sample(range(400), 12)
    xs = list(range(10)); r.shuffle(xs); rec["shuffle"] = xs
    rec["gauss"] = [r.gauss(0.0, 1.0) for _ in range(4)]
    rec["bits40"] = [r.getrandbits(40) for _ in range(2)]
    rec["tail"] = r.random()
    out.append(rec)
json.dump(out, open(sys.argv[1], "w"))
print("vectors:", len(out))
