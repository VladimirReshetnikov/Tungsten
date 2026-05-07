import math
decimals = 16
_log10 = math.log10
max_safe_int = 9007199254740991 # 2^53-1
def correct(x):
    if isinstance(x, (int, float)):
        abs_x = abs(x)
        x = [0 if x >= 0 else 1, abs_x if abs_x < max_safe_int else _log10(abs_x)]
        if abs_x > max_safe_int: return x + [1]
        return x
    if isinstance(x, list):
        x_len = len(x)
        if x_len > 3: return "Infinity"
        if x[0] not in (0, 1): raise ValueError(f"First element must be 0 (positive) or 1 (negative) (array:{x})")
        log10_max_safe_int = _log10(max_safe_int)
        skip = False
        if x_len == 3:
            while x[1] < log10_max_safe_int and x[2] >= 1:
                x[1] = 10**x[1]
                x[2] -= 1
            if x[1] > max_safe_int:
                x[1] = _log10(x[1])
                x[2] += 1
            if x[2] > max_safe_int: x[2] = float(x[2])
            if x[2] == 0:
                skip = True
                x.pop()
        if len(x) == 2 and skip != True:
            if x[1] > max_safe_int:
                x[1] = _log10(x[1])
                x.append(1)
        return x
    if x == "Infinity": return "Infinity"
    raise TypeError("Unsupported type for correct")

def compare(a, b):
    A = correct(a)
    B = correct(b)
    if A == "Infinity" or B == "Infinity": return "Infinity"
    if A[0] != B[0]: return -1 if A[0] == 1 else 1
    lenA = len(A)
    lenB = len(B)
    if lenB > lenA: return -1
    if lenB < lenA: return 1
    if lenA == 3:
        if A[2] != B[2]: return 1 if A[2] > B[2] else -1
        a1 = A[1]
        b1 = B[1]
    else:
        a1 = A[1]
        b1 = B[1]
    if a1 != b1: return 1 if a1 > b1 else -1
    return 0

def lt(a, b): return compare(a, b) == -1
def gt(a, b): return compare(a, b) == 1
def eq(a, b): return compare(a, b) == 0
def lte(a, b): return compare(a, b) != 1
def gte(a, b): return compare(a, b) != -1
def maximum(a, b):
    if gte(a,b): return correct(a)
    else: return correct(b)
def minimum(a, b):
    if lte(a,b): return correct(a)
    else: return correct(b)
def abs_val(x):
    if x == "Infinity": return "Infinity"
    x=correct(x)
    return correct([0] + x[1:])
def lambertw_float(z, tol=1e-10, max_iter=100):
    if z < 1:
        w = z
    else:
        w = math.log(z)
    for _ in range(max_iter):
        ew = math.exp(w)
        w_next = w - (w * ew - z) / (ew * (w + 1))
        if abs(w_next - w) < tol:
            return w_next
        w = w_next
    raise RuntimeError("Lambert W did not converge")
def addlayer(x, layers=1,_add=0):
    if x == "Infinity": return "Infinity"
    arr = correct(x)
    if arr[0] == 1 and len(arr) == 2: return correct([0, 10**(-(arr[1]+_add))])
    if arr[0] == 1 and gt(abs_val(x), [0, 308, 1]): return [0, 0]
    if arr[0] == 1 and len(arr) > 2: return [0, 0]
    if len(arr) == 2: return correct([0, arr[1], 1])
    if len(arr) == 3: return correct([0, arr[1], arr[2] + layers])
    if len(arr) > 3: return "Infinity"
    return arr
def log(x):
    arr = correct(x)
    if arr == "Infinity": return "Infinity"
    if arr[0] == 1: raise ValueError("Can't log a negative")
    if len(arr) == 2: return [0, _log10(arr[1])]
    if len(arr) == 3: return correct([0, arr[1], arr[2] - 1])
    if len(arr) > 3: return "Infinity"
    return correct(arr)
def slog(x):
    if x == "Infinity": return "Infinity"
    x = correct(x)
    if x[0] == 1: raise ValueError("Can't slog a negative")
    if lte(x, [0, 10]): return [0, _log10(x[1])]
    if lte(x, [0, 10000000000]): return [0, _log10(_log10(x[1]))+1]
    len_x = len(x)
    if len_x == 2: return [0, _log10(_log10(_log10(x[1])))+2]
    if len_x == 3: return [0, _log10(_log10(x[1]))+x[2]+1]
    return "Infinity"
def tofloat(a):
    if a == "Infinity": return "Infinity"
    if gt(a, [0, 308.2547155599, 1]): return None
    a = correct(a)
    val = a[1]
    if len(a) == 3: val = 10**val
    return -val if a[0] == 1 else val

def tofloatfast(x):
    if isinstance(x, (int, float)): return x
    try: float(x)
    except: pass
    if x == "Infinity": return "Infinity"
    if gt(x, [0, 308.2547155599, 1]): return None
    val = x[1]
    if len(x) == 3: val = 10**val
    return -val if x[0] == 1 else val
def neg(x):
    if x == "Infinity": return "Infinity"
    correct(x)
    x[0] = int(not x[0])
    return x
def add(a, b):
    if a == "Infinity" or b == "Infinity": return "Infinity"
    a, b = correct(a), correct(b)
    if gt(a, [0, 15.95458977019, 2]) or gt(b, [0, 15.95458977019, 2]): return maximum(a,b)
    if a[0] == 1 and b[0] == 1: return neg(add(neg(a),neg(b)))
    if a[0] == 1 and b[0] == 0: return subtract(b, neg(a))
    if a[0] == 0 and b[0] == 1: return subtract(a, neg(b))
    if len(a) == 3 or len(b) == 3:
        if (len(a) > 2 and a[2] > 1) or (len(b) > 2 and b[2] > 1): return maximum(a, b)
    if len(a) == 2 and len(b) == 2: return correct([0, tofloat(a) + tofloat(b)])
    loga = tofloat(log(a))
    logb = tofloat(log(b))
    M = max(loga, logb)
    m = min(loga, logb)
    return addlayer(M + tofloat(log(1 + 10**(m - M))))
def subtract(a,b):
    if a == "Infinity" and b == "Infinity": return [0, 0]
    if a == "Infinity" or b == "Infinity": return "Infinity"
    a, b = correct(a), correct(b)
    if eq(a,b) and a[0] == b[0]: return [0,0]
    if eq(a,b): return neg(add(abs_val(a),abs_val(b)))
    if gt(a, [0, 15.954589770191003, 2]) or gt(b, [0, 15.954589770191003, 2]):
        if gt(b,a): return neg(b)
        if gt(a,b): return a
    if a[0] == 1 and b[0] == 1: return neg(subtract(abs_val(b), abs_val(a)))
    if a[0] == 1 and b[0] == 0: return neg(addlayer(tofloat(log(abs_val(a))) + tofloat(log(1 + tofloat(addlayer(tofloat(log(b)) - tofloat(log(abs_val(a)))))))))
    if a[0] == 0 and b[0] == 1: return add(a, abs_val(b))
    if lt(a,b):
        if a[0] == 0 and b[0] == 0: return neg(addlayer(tofloat(log(a)) + tofloat(log(abs_val(1 - tofloat(addlayer(tofloat(log(b)) - tofloat(log(a)))))))))
    if a[0] == 0 and b[0] == 0: return addlayer(tofloat(log(a)) + tofloat(log(1 - tofloat(addlayer(tofloat(log(b)) - tofloat(log(a)))))))

def multiply(a, b):
    if a == "Infinity" or b == "Infinity": return "Infinity"
    A = correct(a)
    B = correct(b)
    result_sign = A[0] ^ B[0]
    if gt(A, [0, max_safe_int, 1]): return A
    if len(A) == 2 and len(B) == 2:
        val = (A[1] if A[0] == 0 else -A[1]) * (B[1] if B[0] == 0 else -B[1])
        return correct([0 if val >= 0 else 1, abs(val)])
    result = addlayer(add(log(A), log(B)))
    return result if result_sign == 0 else neg(result)

def divide(a, b):
    if a == "Infinity" and b == "Infinity": raise ValueError("Infintiy/Infinity is undefined")
    if a == "Infinity": return "Infinity"
    if b == "Infinity": return [0, 0]
    A = correct(a)
    B = correct(b)
    if A[0] ^ B[0] == 1: return neg(divide(abs_val(A), abs_val(B)))
    if A[0] == 1: divide(abs_val(A), abs_val(B))
    if eq(B, 0): raise ZeroDivisionError("Can't divide with 0")
    if gt(maximum(A,B), [0, max_safe_int, 2]): return A if gt(A,B) else 0
    if len(B) == 2 and len(A) == 2: return correct([0, tofloat(A) / tofloat(B)])
    if eq(log(A),[0, 0]): return addlayer(subtract(A, log(B)), _add=1)
    result = subtract(log(A), log(B))
    return addlayer(result)

def power(a, b):
    if a == "Infinity" or b == "Infinity": return "Infinity"
    A = correct(a)
    B = correct(b)
    if B[0] == 1 and A[0] != 1: return divide(1, power(a,neg(b)))
    if B[0] == 1 and A[0] == 1: return divide(1, power(neg(a),neg(b)))
    if A[0] == 1: return addlayer(multiply(log(neg(A)), B))
    return addlayer(multiply(log(A), B))

def tetr(x,y):
    if x == "Infinity" or y == "Infinity": return "Infinity"
    x1, y = tofloatfast(x), tofloatfast(y)
    if y == None: return "Infinity"
    if x1 == None:
        y_floor = math.floor(y)
        frac = y-y_floor
        return addlayer(multiply(power(x, frac), log(x)),y_floor)
    if x1 < 1.444667861009766:
        n = -math.log(x1)
        return lambertw_float(n)/n
    y_floor = math.floor(y)
    frac = y-y_floor
    end = math.exp(frac * math.log(x1)) if frac != 0 else 1.0
    skip = 0
    try:
        while y_floor > 0 and skip != 1000:
            end = x1**end
            y_floor -= 1
            skip += 1
    except OverflowError: end *= math.log10(x1)
    return correct([0, end, y_floor])
def logbase(a,b):
    if lte(b, 1): raise ValueError("LogBase undefined for bases under or equal to 1")
    return divide(log(a),log(b))
def ln(a): return multiply(log(a),2.302585092994046) # log10(a)/log10(e) or log10(a)*(1/log10(e))
def sqrt(a): return root(a,2)
def root(a,b): 
    if lt(b,0): raise ValueError("Can't root a negative")
    if gt(b,0) and lt(b,1): return power(a,divide(1,b))
    if eq(b, 0): raise ValueError("Root of 0 is undefined")
    return addlayer(divide(log(a),b))
def exp(x): return power(2.718281828459045, x)
def comma_format(num, precision=0):
    a = correct(num)
    if len(a) == 2:
        val = a[1]
        if precision == 0: return f"{int(round(val)):,}"
        else: return f"{val:,.{precision}f}"
    return str(a)

def regular_format(num, precision):
    a = correct(num)
    if len(a) == 2:
        val = a[1]
        if precision == 0: return f"{int(val):,}"
        else: return f"{val:.{precision}f}"
    return a
def format(num, decimals=decimals, small=False):
    precision2 = max(5, decimals)
    n = correct(num)
    if len(n) == 2 and abs(n[1]) < 1e-308: return f"{0:.{decimals}f}"
    if n[0] == 1: return "-" + format(neg(n), decimals)
    if lt(n, 0.0001):
        inv = 1/tofloat(n)
        return "1/" + format(inv, decimals)
    elif lt(n, 1): return regular_format(n, decimals + (2 if small else 0))
    elif lt(n, 1000): return regular_format(n, decimals)
    elif lt(n, 1e9): return comma_format(n)
    elif lt(n, [0, 10000000000, 3]):
        bottom = num[1]
        rep = num[2] - 1
        if bottom >= 1e9:
            bottom = math.log10(bottom)
            rep += 1
        m = 10 ** (bottom - math.floor(bottom))
        e = math.floor(bottom)
        p = precision2 if bottom < 1_000_000 else 2
        return ("e" * int(rep)) + regular_format([0, m], p) + "e" + comma_format(e)
    else:
        if lt(num,[0, 10000000000,9007199254740989]):
            while num[1] > 10: 
                num[1] = math.log10(num[1])
                num[2] += 1
            return format(num[1]) + "F" + format(num[2],0)
        return "F"+ format(num[2])
def hyper_e(x):
    if x == "Infinity": return "Infinity"
    x = correct(x)
    sign = "E"
    if x[0] == 1: sign = "-E"
    if len(x) == 3: return sign + str(x[1]) + "#" + str(x[2])
    return sign + str(x[1])
