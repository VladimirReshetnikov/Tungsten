#!/usr/bin/env python3
# encoding: utf-8
# Compatible with python2 (or should be)
from __future__ import division
import math
import re
from sys import version_info
from numbers import Number

if version_info.major < 3:
    PY3 = False
    input = raw_input
    BASESTR=basestring
else:
    PY3 = True
    BASESTR=str

class Hypernum:
    """
    Hypernum class, after Robert Munafo's Hypercalc program.

    Usual binary ops are defined, as well as factorial() and gamma()
    methods, and log10(), ln(), exp(), pow10(), sqrt(), etc.
    """

    # As written, you have to write 0.5, not .5.
    hypre='(?P<pt>\\d+[pP])?(?P<sign>[+-])?(?P<int>\\d+)(?P<frac>\\.\\d*)?(?:[eE⏨](?P<exp>[+-]?\\d+))?'
    if not PY3:
        hypre=hypre.decode('utf8')
    hypre_compiled=re.compile(hypre)
    cutoff=300
    overflow=1e300
    scale=14
    logten=math.log(10)
    latex_pt_limit=3
    latex_exp_limit=0
    str_pt_limit=6
    str_exp_limit=16
    str_p1_exp_limit=11

    def __init__(self, arg=None, **kwargs):
        """
        Hypernum(<number or string>)

        Numbers can be ints/longs or floats.  Strings can be of the 1.234e5
        form used by floats, or of form '12p3.4567e90' to specify Power Tower
        12.  Special strings 'Inf', '-Inf' and 'NaN' are supported.
        """
        # pt and expon must be an integers, mantissa is a float.
        # Uncertainty...?
        # Store mantissa as full float and not store expon?
        # storing separately prevents certain intermediate overflows.

        # Number is 10^(10^(10^...(10^(mantissa * 10^expon)...)))
        # where the number of 10s is the PT.

        # Sign?  Negative PT?  Negative PT would apply only to the
        # first exponent 10.  Sign is sign of mantissa.

        self.pt=0
        self.mantissa=0
        self.expon=0
        try:
            # For overflow errors from huge long ints.
            zz=float(arg)
        except OverflowError:
            arg=str(arg)
        except (TypeError, AttributeError, ValueError):
            # If it's a dict, etc.
            pass
        if arg is None:         # arg takes precedence, though.
            arg=kwargs
        if isinstance(arg, dict):
            if 'pt' in arg and 'mantissa' in arg and 'exp' in arg:
                self.pt=arg['pt']
                self.mantissa=arg['mantissa']
                self.expon=arg['exp']
            else:
                raise ValueError()
        elif isinstance(arg, float) or isinstance(arg, int):
            self.pt=0
            self.mantissa=arg
            self.expon=0
        elif isinstance(arg, self.__class__):
            self.pt=arg.pt
            self.mantissa=arg.mantissa
            self.expon=arg.expon
        elif isinstance(arg,BASESTR):
            if arg == 'Inf':
                self.mantissa=float('Inf')
            elif arg == '-Inf':
                self.mantissa=float('-Inf')
            elif arg == 'NaN':
                self.mantissa=float('NaN')
            else:
                match=self.hypre_compiled.match(arg)
                assert match
                if match.group('pt'):
                    self.pt=int(match.group('pt')[:-1])
                else:
                    self.pt=0
                try:
                    self.mantissa=int(match.group('int') or 0)+float(match.group('frac') or 0)
                    self.expon=0
                except OverflowError:
                    # Long int too large to convert to float
                    # Have to do it ourselves.
                    self.mantissa=float(match.group('int')[:10])
                    self.expon=len(match.group('int'))-10
                self.expon+=int(match.group('exp') or 0)
                self.mantissa *= -1 if match.group('sign')=='-' else 1
                # Uncertainty?
        self.normalize()

    def normalize(self):
        """Normalize hypernum into canonical form, viz.:

        1 <= |mantissa| < 10 (sometimes might show as 10 due to rounding)
        (unless mantissa==0)
        expon == int(expon); |expon| <= 300
        pt == int(pt); pt >= 0
        |mantissa*10^expon| > 300 unless pt==0
        """
        assert self.pt==int(self.pt)
        assert self.pt>=0
        if self.isinf() or self.isnan():
            return
        digits=0
        sign= -1 if self.mantissa < 0 else 1
        self.mantissa *= sign
        if self.mantissa>0:
            digits=int(math.floor(math.log10(self.mantissa)))
        if digits != 0:         # Unnecessary test.
            self.expon += digits
            self.mantissa *= pow(10, -digits)
        assert self.expon == int(self.expon)

        while self.expon > self.cutoff: # while?? Seriously??
            self.mantissa=self.expon + math.log10(self.mantissa)
            digits=math.floor(math.log10(self.mantissa))
            self.expon = int(digits)
            self.mantissa *= pow(10, -digits)
            self.pt += 1
        # May have to demote
        while self.float() <= self.cutoff and self.pt > 0:
            self.mantissa=pow(10,self.float())
            digits=math.floor(math.log10(self.mantissa))
            self.expon=int(digits)
            self.mantissa *= pow(10, -digits)
            self.pt -= 1
        self.mantissa *= sign
        # Uncomment if you need to test?
        # assert 1 <= self.mantissa < 10 or self.mantissa==0
        # assert self.expon == int(self.expon)
        # assert abs(self.expon) <= 300
        # assert self.pt == int(self.pt)
        # assert self.pt >= 0
        # assert abs(self.mantissa*pow(10,self.expon)) > self.cutoff or self.pt==0

    @staticmethod
    def _lambertw(z):
        "Compute W function of float by Newton's method"
        epsilon=1e-14
        # Newton's method.  z is a float!
        if z<5:
            w=0
        else:
            w=math.log(z)-math.log(math.log(z))
        lastw=-1000
        while abs(lastw-w)>epsilon:
            lastw=w
            w=w-(w*math.exp(w)-z)/(math.exp(w)*(1+w))
        return w

    def isnan(self):
        "True if hypernum is NaN"
        return math.isnan(self.mantissa)

    def ispinf(self):
        "True if hypernum is positive infinity"
        return self.mantissa > 0 and math.isinf(self.mantissa)

    def isminf(self):
        "True if hypernum is negative infinity"
        return self.mantissa < 0 and math.isinf(self.mantissa)

    def isinf(self):
        "True if hypernum is infinite, positive or negative"
        return math.isinf(self.mantissa)

    def iszero(self):
        "True if hypernum is zero"
        return self.mantissa == 0

    def _struct(self):
        """Return string spelling out inner structure of hypernum
        This string may be eval()d to produce a dict suitable for feeding
        back into the contructor, if for some reason you want that."""
        return "{{'pt': {x.pt}, 'mantissa': {x.mantissa}, 'exp': {x.expon}}}".format(x=self)

    def _dict(self):
        # Probably should have made this instead of/before _struct()
        """Dictionary of structure.

        Return a dictionary of this Hypernum's pt, mantissa, and expon.  Can
        be used to construct/copy, if needed.
        """
        return {'pt': self.pt, 'mantissa': self.mantissa, 'exp': self.expon}

    # Maybe allow for Unicode with 1.2345⏨15, and/or 6.02×10²³?  One level
    # only though.
    def __repr__(self):
        "x.__repr__() <=> repr(x)"
        if self.isnan():
            return "{.__class__.__name__}('NaN')".format(self)
        if self.ispinf():
            return "{.__class__.__name__}('Inf')".format(self)
        if self.isminf():
            return "{.__class__.__name__}('-Inf')".format(self)
        if self.pt < 1:
            if self.expon < 16:
                return (self.__class__.__name__+
                        "({0!r})".format(self.mantissa * pow(10, self.expon)))
            return (self.__class__.__name__+
                    "({0!r}e+{1:d})".format(self.mantissa, self.expon))
        if self < 0:
            s='-'
        else:
            s=''
        if self.pt == 1 and self.expon < 11:
            m=abs(self.mantissa) * pow(10, self.expon)
            d=int(math.floor(m)) # int makes it python2-compatible
            m=pow(10, m - d)
            return self.__class__.__name__+"('{0:s}{1!r}e+{2:d}')".format(s, m, d)
        return "{x.__class__.__name__}('{x.pt:d}p{x.mantissa!r}e{x.expon:d}')".format(x=self)

    def __str__(self, pt=None):
        "x.__str__() <=> str(x)"
        if self.isnan():
            return "NaN"
        if self.ispinf():
            return "Inf"
        if self.isminf():
            return "-Inf"
        s='-' if self.mantissa<0 else ''
        if pt is None:
            pt=self.pt
        else:
            s=''                # No negatives in recursive call.
        # Format self AS IF self.pt were pt.
        if pt < 1:
            if self.expon < self.str_exp_limit:
                rv= "{0:.1f}".format(self.mantissa * pow(10, self.expon))
            else:
                rv="{0:g} * 10^{1:d}".format(self.mantissa, self.expon)
        elif pt == 1 and self.expon < self.str_p1_exp_limit:
            m=abs(self.mantissa) * pow(10, self.expon)
            d=int(math.floor(m))
            m=pow(10, m - d)
            rv= "{0:s}{1:g} * 10^{2:d}".format(s, m, d)
        elif pt < self.str_pt_limit:
            rv= "{0:s}10^({1:s})".format(s,self.__str__(pt-1))
        else:
            rv="{0:s}{1:d} PT {2:f}e{3:d}".format(s, pt, abs(self.mantissa), self.expon)
        return rv

    @staticmethod
    def _latex_scinote(mant, ex):
        """Format arguments (mantissa, exponent) into scientific notation in
        LaTeX, for LaTeX rendering."""
        # What looks best?  There's something nice about the
        # subscripted 10, and it would let us raise the
        # latex_pt_limit

        # return "{0:g}{{\\rm e}}{{{1:d}}}".format(mant,ex)
        # return "{0:g}e{{{1:d}}}".format(mant,ex)
        # return "{0:g}_{{10}}{1:d}".format(mant,ex)
        return "{0:g}\\times 10^{{{1:d}}}".format(mant,ex)

    def _repr_latex_(self, pt=None):
        "LaTeX representation, for IPython."

        if self.isnan():
            return "$\\rm NaN$"
        if self.ispinf():
            return '$\\infty$'
        if self.isminf():
            return '$-\\infty$'
        s='-' if self.mantissa<0 else ''
        if pt is None:
            pt=self.pt
            outermost=True
        else:
            s=''
            outermost=False
        if pt<1:
            if self.expon<self.str_exp_limit:
                rv= "{0:.1f}".format(self.mantissa * pow(10, self.expon))
            else:
                rv= self._latex_scinote(self.mantissa, self.expon)
        elif pt == 1 and self.expon < self.str_p1_exp_limit:
            m=abs(self.mantissa) * pow(10, self.expon)
            d=int(math.floor(m))
            m=pow(10, m - d)
            rv=self._latex_scinote(self.sign()*m, d)
        elif pt < self.latex_pt_limit:
            rv="{0:s}10^{{{1:s}}}".format(s,self._repr_latex_(pt-1))
        else:
            rv= "{0:s}{1:d} {{\\rm \\ PT\\ }} ".format(s, pt) + self._latex_scinote(abs(self.mantissa), self.expon)
        if outermost:
            return "$"+rv+"$"
        else:
            return rv


    def sign(self):
        "Sign of mantissa.  Zero is considered positive."
        return -1 if self.mantissa < 0 else 1 # No zero.

    def __gt__(self, other):
        "x.__gt__(y) <==> x > y"
        if self.isminf():
            return False
        if not isinstance(other, self.__class__):
            other=self.__class__(other)
        if self.isnan() or other.isnan():
            return False
        if self.ispinf():
            return not other.ispinf()
        if other.isminf():
            return True
        if self.sign() != other.sign():
            if self.sign() > 0:
                return True
            else:
                return False
        if self.sign() < 0:
            reverse=True
        else:
            reverse=False
        if self.pt > other.pt:
            return True ^ reverse
        elif self.pt < other.pt:
            return False ^ reverse
        # Special case!  If one has a negative expon and the other
        # is *ZERO*, which has an expon of 0, comparing the expons
        # gives the wrong answer!
        if not (self.mantissa and other.mantissa):
            return bool(self.mantissa) ^ reverse
        if self.expon > other.expon:
            return True ^ reverse
        elif self.expon < other.expon:
            return False ^ reverse
        return (self.mantissa > other.mantissa)

    def __eq__(self, other):
        "x.__eq__(y) <==> x==y"
        if not isinstance(other, self.__class__):
            other=self.__class__(other)
        if self.isnan() or other.isnan():
            return False
        if self.ispinf():
            return other.ispinf()
        if self.isminf():
            return other.isminf()
        return (self.pt == other.pt and self.expon == other.expon and
                self.mantissa == other.mantissa)

    def __ge__(self, other):
        "x.__ge__(y) <==> x >= y"
        return self > other or self == other

    def __lt__(self, other):
        "x.__lt__(y) <==> x < y"
        if not isinstance(other, self.__class__):
            other=self.__class__(other)
        return other > self

    def __le__(self, other):
        "x.__le__(y) <==> x <= y"
        return self < other or self == other

    def __ne__(self, other):
        "x.__ne__(y) <==> x != y"
        return not self == other

    def __abs__(self):
        "Return copy of hypernum with sign set positive."
        rv=self.__class__(self)
        rv.mantissa=abs(rv.mantissa)
        return rv

    @classmethod
    def _max(cls, one, other):
        "Return maximum of arguments, converting to class if needed."
        if not isinstance(one, cls):
            one=cls(one)
        if not isinstance(other, cls):
            other=cls(other)
        if one > other:
            return one
        else:
            return other

    @classmethod
    def _inorder(cls, one, other):
        "Return arguments in magnitude order, converting to class if needed."
        # In order of magnitude, independent of sign!!
        # ?????
        if not isinstance(one, cls):
            one=cls(one)
        if not isinstance(other, cls):
            other=cls(other)
        if one.sign() != other.sign():
            if one.sign()>=0:
                return one, other
            else:
                return other, one
        if one > other and one.sign()>=0 or one < other and one.sign()<0:
            return one, other
        else:
            return other, one

    def float(self):
        "Floating-point part of hypernum; power-tower considered to be zero."
        # Ignore pt!
        return self.mantissa*pow(10,self.expon)

    @staticmethod
    def _addlog(la,lb):
        "Log of sum of antilog"
        # log of sum of antilog:
        # log10(a) + log10(1+10^(log10(b)-log10(a)))
        # Being passed log10(a) and log10(b), a>b
        return la + math.log10(1+pow(10,lb-la))

    @staticmethod
    def _sublog(la,lb):
        return la + math.log10(1-pow(10,lb-la))

    @staticmethod
    def _gamma(n):
        "gamma function of floating-point number"
        # Math and method copied from hypercalc
        if n < -50:
            if n==int(n):
                return float('inf')
            return 0
        acc=1
        while n<10:
            acc *= n
            n += 1
        n -= 1
        l = 0.5*math.log(2*math.pi)
        l += (n+0.5)*math.log(n)
        l -= n
        n2 = n*n
        np = n
        l += 1.0/(12.0*np)
        np *= n2
        l -= 1.0/(360.0*np)
        np *= n2
        l += 1.0/(1260.0*np)
        np *= n2
        l -= 1.0/(1680.0*np)
        np *= n2
        l += 1.0/(1188.0*np)
        np *= n2
        l -= 691.0/(360360.0*np)
        np *= n2
        l += 7.0/(1092.0*np)
        np *= n2
        l -= 3617.0/(122400.0*np)
        rv=math.exp(l)/acc
        #if abs(rv-int(rv))<1e-5: # nice to round if really close.
        #    return math.floor(rv+0.5)
        #else:
        #    return rv
        return rv

    def gamma(self):
        "Gamma function"
        # Math and method copied from hypercalc
        if self.ispinf():
            return self.Inf
        if self.isminf():
            return self.mInf
        if self.isnan():
            return self.NaN

        n=self.float()
        if self.sign()<0:
            if self.pt>0:
                return self.Inf
            else:
                return self.__class__(self._gamma(n))

        if self.pt==0:
            if self.float()<24:
                return self.__class__(self._gamma(n))

            t = n-1
            l = 0.5*math.log(2*math.pi)
            l += (t+0.5)*math.log(t)
            l -= t
            n2 = t*t
            np = t
            lm = 12.0*np
            adj = 1.0/lm
            l2 = l+adj
            if l2 == l:
                return self.__class__(l).exp()
            l = l2
            np *= n2
            lm = 360.0*np
            adj = 1.0/lm
            l2 = l-adj
            if l2==l:
                return self.__class__(l).exp()
            l = l2
            np *= n2
            lm = 1260.0*np
            lt = 1.0/lm
            l += lt
            np *= n2
            lm = 1680.0*np
            lt = 1.0/lm
            l -= lt
            return self.__class__(l).exp()
        elif self.pt == 1:
            rv = self.ln()
            rv = rv + -1
            rv = self*rv
            return rv.exp()
        else:
            return self.exp()

    # Leave these commented out because it's Python2-incompatible.
    # Γ=gamma                     # Because I feel like it.

    def factorial(self):
        "Factorial; x.factorial()==(x+1).gamma()"
        # Often won't matter...
        if self.pt>0 or self.expon > 15:
            return self.gamma()
        else:
            return (self + 1).gamma()

    # ǃ=factorial                 # U+01C3 LATIN LETTER RETROFLEX CLICK

    def __add__(self, other):
        "x.__add__(y) <==> x+y"
        if (self>0) != (other>0):
            return self.__sub__(-other)
        x, y=self._inorder(self,other)
        sign=x.sign()
        if x.ispinf():
            return self.Inf
        if x.isnan():
            return self.NaN
        if x.isminf():
            return self.mInf
        if x.pt==0:
            return self.__class__(x.float()+y.float())
        elif x.pt==1:
            if y.pt==0:
                val=sign*self._addlog(abs(x.float()), math.log10(abs(y.float())))
            else:
                val=sign*self._addlog(abs(x.float()), abs(y.float()))
            return self.__class__({'pt':1, 'exp':0, 'mantissa':val})
        else:
            return self.__class__(x)

    def __sub__(self, other):
        "x.__sub__(y) <==> x-y"
        if (self>0) != (other>0):
            return self.__add__(-other)
        x, y=self._inorder(self,other)
        if self is x:
            sign = self.sign()
            slf,oth = x,y
        else:
            sign = -self.sign();
            slf,oth = y,x
        if x.ispinf():
            return self.Inf
        if x.isnan():
            return self.NaN
        if x.isminf():
            return self.mInf
        if x.pt==0:
            return self.__class__(slf.float()-oth.float())
        if x==y:
            return self.Zero    # avoid exceptions farther along.
        elif x.pt==1:
            if y.pt==0:
                val=sign*self._sublog(abs(x.float()), math.log10(abs(y.float())))
            else:
                val=sign*self._sublog(abs(x.float()), abs(y.float()))
            return self.__class__({'pt':1, 'exp':0, 'mantissa':val})
        else:
            return self.__class__(x)

    def __rsub__(self, other):
        "x.__rsub__(y) <==> y-x"
        return (-self).__add__(other)

    def log10(self):
        "Logarithm to base 10"
        if self.iszero():
            return self.mInf
        if self.isinf():
            return self.Inf
        if self.isnan():
            return self.NaN
        # Ignore sign.  Re(log(x))=log(|x|)
        if self.pt==0:
            rv = self.__class__(math.log10(abs(self.mantissa))+self.expon)
            return rv
        else:
            rv=self.__class__(self)
            rv.mantissa=abs(rv.mantissa)
            rv.pt -= 1
            return rv

    def pow10(self):
        "Antilog to base 10; 10**x"
        # XXX Negatives!
        if self.ispinf():
            return self.Inf
        if self.isminf():
            return self.Zero
        if self.isnan():
            return self.NaN
        if self.iszero():
            return self.One
        if self.pt==0:
            if abs(self.float())<self.cutoff:
                return self.__class__({'pt':0, 'exp':0,
                                       'mantissa':
                                       pow(10, self.float())})
        if self < 0:
            return self.Zero
        rv=self.__class__(self)
        rv.pt+=1
        return rv

    def exp(self):
        "Natural antilog; e**x"
        if self.ispinf():
            return self.Inf
        if self.isminf():
            return self.Zero
        if self.isnan():
            return self.NaN

        x=self.float()
        if self.pt==0:
            if abs(x) < self.logten/self.cutoff:
                return self.__class__(math.exp(x))
            if abs(x)/self.logten < self.overflow:
                return self.__class__(dict(pt=1, mantissa=x/self.logten, exp=0))
            else:
                # I don't think this can happen.
                return self.__class__(dict(pt=2, exp=0,
                                           mantissa=math.log10(x/self.logten)))
        if x < 0:
            return self.Zero

        if self.pt == 1:
            l1=x+math.log10(math.log10(math.exp(1)))
            if l1 < self.logten/self.cutoff:
                return self.__class__(dict(pt=1, exp=0,
                                           mantissa=math.log10(math.exp(1))*pow(10,x)))
            else:
                return self.__class__(dict(pt=2, mantissa=l1, exp=0))
        else:
            rv=self.__class__(self)
            rv.mantissa=abs(rv.mantissa)
            rv.pt+=1
            return rv

    def ln(self):
        "Natural logarithm."
        if self.isnan():
            return self.NaN
        if self.iszero():
            return self.mInf
        if self.isinf():
            return self.Inf
        # Ignore sign; Re(log(-x))=log(x)
        x=abs(self.float())
        if self.pt==0:
            return self.__class__(math.log(x))
        if self.pt==1:
            l1=x*self.logten
            if l1<self.overflow:
                return self.__class__(l1)
            else:
                return self.__class__(dict(pt=1, exp=0,
                                           mantissa=math.log10(l1)))
        if self.pt==2:
            l1=x-math.log10(math.log10(math.exp(1)))
            if l1 < self.logten/self.cutoff:
                return self.__class__(dict(pt=0, exp=0,
                                           mantissa=pow(10,l1)))
            else:
                return self.__class__(dict(pt=1, exp=0, mantissa=l1))
        else:
            rv=self.__class__(self)
            rv.pt -= 1
            rv.mantissa=abs(rv.mantissa)
            return rv

    def iterpow(self, power):
        "Exponentiation by iterated multiplication"
        # Iterative power: just repeated multiplication
        if power == power-1:
            raise ValueError("Power too big")
        rv=self.One
        while power>0:
            rv = rv * self
            power -= 1
        return rv

    def itertetra(self, power):
        "Tetration by iterated exponentiation"
        # Iterative tetration.  Repeated exponentiation.
        # At least catch truly infinite loops;
        # you can still screw up badly if you want though.
        if power == power-1:
            raise ValueError("Tetration too big")
        power=int(power)          # avoid rounding problems.
        rv=self.One
        while power>0:
            rv = self ** rv  # Order matters!
            power -= 1
        return rv

    def __neg__(self):
        "x.__neg__() <==> -x"
        rv=self.__class__(self)
        rv.mantissa *= -1
        return rv

    def __bool__(self):
        "True if non-zero"
        return self.mantissa != 0

    def __pow__(self, power):
        "x.__pow__(y) <==> x**y"
        if not isinstance(power, self.__class__):
            power=self.__class__(power)
        if power.iszero():
            return self.One
        if power == self.One:
            return self.__class__(self)
        if power.ispinf():
            return self.NaN
        if power.isminf():
            return self.Zero
        if power.isnan():
            return self.NaN
        if self.isnan():
            return self.NaN
        if self.ispinf():
            return self.Inf
        if self.isminf():
            return self.NaN
        if self.iszero():
            return self.Zero
        if power < 0:
            raise ValueError("Negative powers not supported")
#        if self < self.One:
#            raise ValueError("Powers of bases <1 not supported")
        # general case.  Does it need to be more complicated than this?
        rv=(abs(self).log10()*power).pow10()
        sign=self.sign()
        # Only even integer powers go only positive.  Non-integer
        # powers on negative numbers?  You're on your own.  I'm
        # returning negative.  Anything bigger than 10**15 is an even
        # integer, since that's about my precision, so it would end in
        # a zero.
        if (power.pt > 0 or power.expon > 15 or
            (power.float()==int(power.float()) and
             int(power.float())%2 == 0)):
            sign=1
        return sign*rv

    def sqrt(self):
        "Square root"
        return self ** 0.5

    def __rpow__(self, base):
        "x.__rpow__(y) <==> y**x"
        # Probably do need this.
        if not isinstance(base, self.__class__):
            return self.__class__(base).__pow__(self)
        else:                   # ??
            return base.__pow__(self)

    def __rmul__(self, other):  # Needed?
        "x.__rmul__(y) <==> y*x"
        return self.__mul__(other)

    def __mul__(self, other):
        "x.__mul__(y) <==> x*y"
        a, b = self._inorder(self, other)
        if a.isnan() or b.isnan():
            return self.NaN
        if a.iszero() or b.iszero():
            return self.Zero
        if a.sign() != b.sign():
            sign = -1
        else:
            sign = 1
        if b.isminf() or a.ispinf():
            if sign > 0:
                return self.Inf
            else:
                return self.mInf
        if a.pt==0:
            rv=abs(a.float()) * abs(b.float())
            if rv>self.overflow:
                return self.__class__({'pt':1, 'exp':0,
                                       'mantissa':sign * (math.log10(abs(a.mantissa))+
                                                          math.log10(abs(b.mantissa))+
                                                          a.expon+b.expon)})
            return self.__class__(rv*sign)
        if a.pt==1 and b.pt==0:
            rv=abs(a.float())+math.log10(abs(b.mantissa))+b.expon
            return self.__class__({'pt':1, 'exp':0, 'mantissa':sign*rv})
        if a.pt==1 and b.pt==1:
            rv=abs(a.float())+abs(b.float())
            return self.__class__({'pt':1, 'exp':0, 'mantissa':sign*rv})
        if a.pt==2:
            if b.pt==2:
                if abs(a.float())-abs(b.float()) < self.scale:
                    return self.__class__({'pt':2, 'exp':0,
                                           'mantissa':sign*self._addlog(abs(a.float()),
                                                                        abs(b.float()))})
        return self.__class__(a)

    def __truediv__(self, other):
        "x.__truediv__(y) <==> x/y"
        if not isinstance(other, self.__class__):
            other=self.__class__(other)
        if self.isnan() or other.isnan():
            return self.NaN
        selfsign=self.sign()
        othersign=other.sign()
        rvsign=selfsign*othersign
        if other.iszero():
            return self.NaN     # or +-Inf?  Or raise exception?
        if self.isinf():
            if rvsign<0:
                return self.mInf
            else:
                return self.Inf
        if self.iszero():
            return self.Zero
        if self.pt==0 and other.pt==0:
            rv=abs(self.float()) / abs(other.float())
            if rv>self.overflow:
                rv=self.log10()-other.log10()
                rv.mantissa *= rvsign
                rv.pt=1
                return rv
            else:
                return self.__class__(rv*rvsign)
        if self.pt==1 and other.pt==0:
            rv=abs(self.float())-abs(other.log10().float())
            if rv > self.cutoff:
                return self.__class__(dict(pt=1, exp=0, mantissa=rvsign*rv))
            else:
                return self.__class__(dict(pt=0, exp=0,
                                           mantissa=rvsign*pow(10, abs(rv))))
        if self.pt==0 and other.pt==1:
            rv=math.log10(abs(self.float())) - abs(other.float())
            rv=self.__class__(pow(10,rv)*rvsign)
            return rv
        if self.pt==1 and other.pt==1:
            rv=abs(self.float())-abs(other.float())
            if rv < self.cutoff:
                return self.__class__(rvsign*pow(10,rv))
            else:
                return self.__class__(dict(pt=1, exp=0, mantissa=rvsign*rv))
        if self.pt < other.pt:
            return self.Zero
        if self.pt > other.pt:
            return self.__class__(self)
        else:
            if abs(self.float()) < abs(other.float()):
                return self.Zero
            elif abs(self.float()) == abs(other.float()):
                return self.One * rvsign
            else:
                return self.__class__(self)



    # More magic functions!

    def __float__(self):
        return self.float()

    def __int__(self):
        return int(self.float())

    __long__ = __int__

    __trunc__ = __int__

    # Let's do some notation abuse!  There are all these magic
    # functions hardly anyone ever uses...

    __xor__ = itertetra         # Abuse notation! Use ^ for tetration!

    def __rxor__(self, other):
        if not isinstance(other, self.__class__):
            other=self.__class__(other)
        return other.itertetra(self)

    def __irshift__(self, other):
        "x >>= k: increment the power-tower of x by k"
        other = int(other)
        if self.pt + other >= 0:
            self.pt += other
            self.normalize()
        else:
            raise ValueError("PT would go negative")
        return self

    def __ilshift__(self, other):
        "x <<= k: decrement the power-tower of x by k"
        return self.__irshift__(-other)

    def __round__(self):
        return self
    def __rtruediv__(self, other):
        return self.__class__(other).__truediv__(self)
    def __radd__(self, other):
        return self.__class__(other).__add__(self)
    __floordiv__=__truediv__
    __rfloordiv__=__rtruediv__
    __pos__=__floor__=__ceil__=__round__
    def __mod__(self, other):
        return self
    __rmod__=__mod__


Hypernum.NaN=Hypernum('NaN')
Hypernum.Inf=Hypernum('Inf')
Hypernum.mInf=Hypernum('-Inf')
Hypernum.One=Hypernum(1)
Hypernum.Zero=Hypernum({'pt':0, 'exp':0, 'mantissa':0.0})
Hypernum.E=Hypernum(math.exp(1))
Hypernum.Pi=Hypernum(math.pi)
Hypernum.Log10E=Hypernum(math.log10(math.exp(1)))
Hypernum.Ln10=Hypernum(math.log(10)) # need both?
Hypernum.Overflow=Hypernum(Hypernum.overflow)

if __name__=='__main__':
    try:
        import readline
    except ImportError:
        pass

    def doInfix():
        operators={"+":11, "-":11, "*":21, "/":21, "**":30, "^":30, "***":30,
                   " BOT ":0, " END ":2, "(":3, ")":4, "ln":50, "exp":50,
                   "sqrt":50, "log10":50, "exp10":50, "gamma":50,
                   "factorial":50}
        # Odd numbers are left-associative.  It makes sense.
        lastx=Hypernum.Zero
        while True:
            try:
                opstack=[" BOT "]    # Restart each line.
                numstack=[]
                # Tokenize somehow?  Split on spaces for now.
                instr=input("-> ").strip()
                tokens=instr.split()
                tokens.append(' END ')
                for tok in tokens:
                    if tok in operators:
                        topprec=operators[opstack[-1]]
                        thisprec=operators[tok]
                        # Special-case left-paren: it's high-prec from one
                        # side (always pushes) and low-prec from the other
                        # (nothing executes it except right-paren)
                        if tok == "(":
                            thisprec=1000
                        while (thisprec < topprec or
                               (thisprec==topprec and thisprec & 1)):
                            op=opstack.pop()
                            topprec=operators[opstack[-1]]
                            if op in ["+", "-", "*", "/", "**"]:
                                y=numstack.pop()
                                x=numstack.pop()
                                res=eval("x"+op+"y")
                                numstack.append(res)
                            elif op=='^':
                                y=numstack.pop()
                                x=numstack.pop()
                                res=x**y
                                numstack.append(res)
                            elif op=='***':
                                y=numstack.pop()
                                x=numstack.pop()
                                res=x.itertetra(y)
                                numstack.append(res)
                            elif op=="(":
                                if tok==")":
                                    break
                            elif op in ["ln", "exp", "sqrt", "log10", "exp10",
                                        "factorial", "gamma"]:
                                x=numstack.pop()
                                res=eval("x."+op+"()")
                                numstack.append(res)
                            elif op == " BOT " or tok == " END ":
                                pass
                            else:
                                raise SyntaxError(tok)
                        if tok != ")":
                            opstack.append(tok)
                    elif tok == '%X':
                        numstack.append(lastx)
                    elif tok == 'e':
                        numstack.append(Hypernum.E)
                    elif tok == 'pi':
                        numstack.append(Hypernum.Pi)
                    else:
                        try:
                            numstack.append(Hypernum(tok))
                        except AssertionError:
                            raise SyntaxError(tok)
                if len(numstack) != 1:
                    raise SyntaxError("Numstack length %d"%len(numstack))
                if opstack != [" BOT ", " END "]:
                    raise SyntaxError("Opstack not empty: %s"%str(opstack))
                lastx=numstack[0]
                print(str(numstack[0]))
            except IndexError as e:
                print("Operations Error: "+str(e))
            except SyntaxError as e:
                print("Syntax Error: "+str(e))
            except ValueError as e:
                print("Value Error: "+str(e))

    def doRPN():
        # RPN is easier to code and easier to debug.
        print("RPN Mode")
        stack=[]
        while True:
            try:
                if len(stack)<8:
                    print(str(stack))
                else:
                    print("({})... ".format(len(stack)-7)+str(stack[-7:]))
                instr=input("-> ").strip()
                for s in instr.split():
                    if s=="+":
                        y = stack.pop()
                        x = stack.pop()
                        stack.append(x+y)
                    elif s=="-":
                        y = stack.pop()
                        x = stack.pop()
                        stack.append(x-y)
                    elif s=="*":
                        y = stack.pop()
                        x = stack.pop()
                        stack.append(x*y)
                    elif s=="/":
                        y = stack.pop()
                        x = stack.pop()
                        stack.append(x/y)
                    elif s=="**" or s=="^":
                        y = stack.pop()
                        x = stack.pop()
                        stack.append(x**y)
                    elif s=="***":
                        y = stack.pop()
                        x = stack.pop()
                        stack.append(x.itertetra(y))
                    elif s=="dup":
                        stack.append(stack[-1])
                    elif s=="drop":
                        stack.pop()
                    elif s=="!" or s=="fact":
                        x=stack.pop()
                        stack.append(x.factorial())
                    elif s=='exp10': # common antilog
                        x=stack.pop()
                        stack.append(pow(10, x))
                    # elif s=="exp":
                    #     x=stack.pop()
                    #     stack.append(x.exp())
                    # elif s=="ln":
                    #     x=stack.pop()
                    #     stack.append(x.ln())
                    # elif s=="log10":
                    #     x=stack.pop()
                    #     stack.append(x.log10())
                    # elif s=="sqrt":
                    #     x=stack.pop()
                    #     stack.append(x.sqrt())
                    # Can/should I do this?  Guess so.
                    # Allowing sign permits non-Hypernums in stack!
                    elif s in ["exp", "ln", "log10", "sqrt", "sign",
                               "factorial", "gamma"]:
                        x=stack.pop()
                        stack.append(eval("x."+s+"()"))
                    elif s=="W":
                        x=stack.pop()
                        # !!!!XXX only does float!
                        stack.append(Hypernum(Hypernum._lambertw(x.float())))
                    elif s=="e":
                        stack.append(Hypernum.E)
                    elif s=="pi":
                        stack.append(Hypernum.Pi)
                    elif s=="inf":
                        stack.append(Hypernum.Inf)
                    elif s=="minf":
                        stack.append(Hypernum.mInf)
                    elif s=="nan":
                        stack.append(Hypernum.NaN)
                    elif s=="_struct":
                        print(stack[-1]._struct()) # for debugging.
                    elif s=="p":
                        print(str(stack[-1]))
                    elif s=="clear":
                        stack=[]
                    elif s=="swap":
                        y = stack.pop()
                        x = stack.pop()
                        stack.append(y)
                        stack.append(x)
                    # At the end; matches too much.
                    elif re.match(Hypernum.hypre+r"$", s):
                        stack.append(Hypernum(s))
                    else:
                        print("Unknown token: "+s)
            except IndexError:
                print("Pop from empty stack!")
            except ValueError as e:
                print("ValueError: "+str(e))

    import sys
    try:
        if sys.argv and len(sys.argv)>1 and sys.argv[1]=='-R':
            doRPN()
        else:
            doInfix()
    except (EOFError, KeyboardInterrupt) as e:
        print("<EOF>")
