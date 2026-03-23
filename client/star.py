import math


t = []
for i in range(10):
    ang = i / 10 * math.tau - math.tau / 4
    r = 0.5 if i % 2 else 1
    t.append(math.cos(ang) * r)
    t.append(math.sin(ang) * r)
print(", ".join(f"{x:.3f}" for x in t))
