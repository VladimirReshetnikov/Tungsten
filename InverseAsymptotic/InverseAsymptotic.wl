(* ::Package:: *)

(* :Title: InverseAsymptotic *)
(* :Context: InverseAsymptotic` *)
(* :Author: Vladimir Reshetnikov *)
(* :Summary:
   Asymptotic expansions of the REAL-VALUED branch of an inverse function.

   Given a real function f and a point x -> a, InverseAsymptotic returns an
   asymptotic expansion of the real branch of f^(-1)(y) as y -> b = lim f, in a
   generalized power-log scale that the built-ins cannot produce.  The built-in
   route

       Series[InverseFunction[Function[x, x + x^2 (1 + Log[x])]][y], {y, 0, 2}]

   returns a series about a *nonzero complex* root of f (it involves
   ProductLog[-1, -E]); InverseFunction inverts f analytically about the complex
   solution of f(x) = 0, not about the real point x = 0.  Asymptotic / InverseSeries /
   AsymptoticSolve either echo the input or return Undefined on such problems,
   because the inverse is NOT an ordinary power series: it carries logarithms
   (x + x^2(1 + Log x)) and/or irrational, incommensurate powers (x + x^Sqrt[2],
   whose inverse runs in exponents 1, Sqrt[2], 2 Sqrt[2]-1, 3 Sqrt[2]-2, ...).

   METHOD.  The real branch is reconstructed by dominant balance + contractive
   fixed-point iteration carried out in a small "transseries" arithmetic over
   monomials  c z^p Log[z]^k  (p an exact real, k a non-negative integer):

     1.  Detect the leading monomial c x^p of f at the point (a pure power; the
         logarithmic / Lambert-W leading case is reported, not guessed).
     2.  Iterate  X <- ((z - f(X) + c X^p)/c)^(1/p)  starting from the real
         leading term X0 = (z/c)^(1/p), expanding and truncating each iterate by
         the real value of its z-exponent.  Because the seed and every step are
         real, the iteration converges to the REAL branch automatically.
     3.  Normalize the point/direction/image (x -> a finite or +-Infinity, from
         above or below; image b finite or +-Infinity) by local substitutions,
         keeping the whole computation in the monomial representation so the final
         expression is emitted clean (no Simplify mangling of Log[1/y] etc.).
     4.  Re-verify the result numerically by back-substitution at high precision:
         f(X(y)) - y must vanish to the claimed remainder order (the PSLQ-canary
         discipline applied to asymptotics).

   SUPPORTED CLASS.  Any f whose leading behaviour at the point is a pure power
   c x^p (p any nonzero real, c real != 0), with corrections built from real
   powers, integer powers of logarithms, and analytic compositions (Exp, Sin,
   ... ).  Both flagship examples above, the elementary inverses (Exp[x]-1 ->
   Log[1+y], Sin -> ArcSin, Tan -> ArcTan, x - x^2 -> Catalan generating
   function, x Exp[x] -> ProductLog -- whose leading term IS the pure power x),
   inversions at a nonzero point, and inversions at infinity (x + Log x,
   x + Sqrt[x]) are all in scope.  When the LEADING term itself carries a
   logarithm (x Log x, whose inverse is a Lambert-W / iterated-logarithm object
   outside the c z^p Log^k scale), the input is detected and reported, rather
   than answered incorrectly; nested logarithms (Log[Log[...]]) in corrections
   are likewise refused, and the rate-based verifier guards against any silent
   truncation.  An even leading order makes the real inverse two-valued; the
   returned branch is the one matching Direction (the other is the opposite
   Direction), and "RealBranches" -> 2 is flagged in the diagnostics.

   Main entry points:
     InverseAsymptotic[f, x, y, n]          -> expansion of f^(-1)(y), n levels
     InverseAsymptoticData[f, x, y, n]      -> Association with full diagnostics
*)

BeginPackage["InverseAsymptotic`"];

InverseAsymptotic::usage =
  "InverseAsymptotic[f, x, y, n] gives an n-level asymptotic expansion of the \
real-valued branch of the inverse of the function x |-> f (an expression in x), \
as a series in the output variable y, valid as y -> f(a) with x -> a (a = 0 from \
above by default).  InverseAsymptotic[f, x -> a, y, n] sets the expansion point. \
The result is an ordinary power-log sum (which may carry logarithms and \
non-integer or irrational powers) plus, by default, an inert BigO[...] remainder \
term -- not a SeriesData object -- and is $Failed on out-of-scale input. \
Options: \"At\" (the point a, default 0; a finite value or +-Infinity), \
Direction (\"FromAbove\"/1 default, or \"FromBelow\"/-1; selects the one-sided \
real branch), \"ImagePoint\" (the image f(a), default Automatic), \"Remainder\" \
(True: append the BigO[...] term), \"Verify\" (True: rate-based numeric \
back-substitution check), \"VerificationTolerance\" (exact-residual floor, \
default 10^-18).";

InverseAsymptoticData::usage =
  "InverseAsymptoticData[f, x, y, n] (also [f, x -> a, y, n]) is like \
InverseAsymptotic but returns an Association with keys \"Expansion\", \
\"Monomials\" (the {coefficient, power, logPower} list for the inverse in x), \
\"LeadingPower\" ({c, p} of f at the point), \"ImagePoint\", \"Side\", \
\"RemainderExponent\", \"InfiniteImage\", \"Sigma\", \"RealBranches\" (1, or 2 \
when the even leading order makes the inverse two-valued), and -- only when \
\"Verify\" -> True -- \"Verified\", \"MaxResidual\", and \"MeasuredOrder\" (the \
empirically measured decay exponent of the back-substitution residual).";

BigO::usage =
  "BigO[v, p] is an inert order term displayed as O(v^p); it marks the remainder \
of an InverseAsymptotic expansion when the remainder cannot be represented by the \
built-in SeriesData (irrational or logarithmic scales).  It is the term appended \
when \"Remainder\" -> True.";

InverseAsymptotic::leadlog =
  "The leading behaviour of `1` at the requested point is not a pure power c x^p \
(its leading term carries a logarithm).  This Lambert-W / iterated-logarithm \
regime is outside the supported power-log scale; no expansion was produced.";
InverseAsymptotic::nolead =
  "Could not determine a real pure-power leading term c x^p of `1` at the \
requested point.";
InverseAsymptotic::verify =
  "Numeric back-substitution verification was weak: the residual f(X(y))-y \
decays like the `1` power of the infinitesimal, below the expected remainder \
order `2`; the returned expansion may be unreliable.  Inspect with \
InverseAsymptoticData and \"Verify\" -> False to suppress this check.";
InverseAsymptotic::badside =
  "Inversion at an infinite image with the image tending to -Infinity is not \
supported in this version; substitute y -> -y by hand.";
InverseAsymptotic::nconv =
  "The fixed-point iteration did not stabilize for `1` within the iteration \
budget; returning the best available truncation (which may be incomplete).";
InverseAsymptotic::branches =
  "f has an even leading order (~ (x - a)^`1`) at the point, so its real inverse \
is two-valued; the returned branch matches Direction -> `2`.  The other real \
branch (to the same image side) is obtained with the opposite Direction.";
InverseAsymptotic::singular =
  "The analytic function `1` is applied to an argument tending to one of its \
singularities; the expansion is outside the supported scale.";

Begin["`Private`"];

$tol = 10.^-9;

(* ================= transseries monomial engine ======================= *)
(* normal form: list of {coef, p, k};  coef z-free, p exact real, k integer >= 0 *)

tlCollect[ml_] := Module[{g},
  g = GatherBy[ml, {#[[2]], #[[3]]} &];
  g = {Simplify[Total[#[[All, 1]]]], #[[1, 2]], #[[1, 3]]} & /@ g;
  g = DeleteCases[g, {c_ /; PossibleZeroQ[c], _, _}];
  SortBy[g, {N[#[[2]]] &, #[[3]] &}]];

tlTrunc[ml_, pcut_] := Select[ml, N[#[[2]]] < pcut - $tol &];

tlTimes[a_, b_, pcut_] := tlCollect@tlTrunc[
   Flatten[Table[{ra[[1]] rb[[1]], ra[[2]] + rb[[2]], ra[[3]] + rb[[3]]},
      {ra, a}, {rb, b}], 1], pcut];

tlPowInt[a_, e_Integer, pcut_] /; e >= 0 := Module[{r = {{1, 0, 0}}, i},
  Do[r = tlTimes[r, a, pcut], {i, e}]; r];

(* dominant monomial: smallest N[p]; among ties, largest k (Log^k grows) *)
tlLead[ml_] := First@SortBy[ml, {N[#[[2]]] &, -#[[3]] &}];

(* divide the whole list by the (log-free) lead monomial c z^p, drop the '1' *)
tlSmallPart[ml_, c_, p_] := DeleteCases[
   tlCollect[{#[[1]]/c, #[[2]] - p, #[[3]]} & /@ ml],
   {_, q_ /; PossibleZeroQ[q], 0}];

tsExp[expr_, z_, pcut_] := Module[{e = expr},
  Which[
    FreeQ[e, z], {{e, 0, 0}},
    e === z, {{1, 1, 0}},
    e === Log[z], {{1, 0, 1}},
    Head[e] === Plus,
      tlCollect@tlTrunc[Join @@ (tsExp[#, z, pcut] & /@ (List @@ e)), pcut],
    Head[e] === Times,
      Fold[tlTimes[#1, tsExp[#2, z, pcut], pcut] &, {{1, 0, 0}}, List @@ e],
    Head[e] === Power && ! FreeQ[e[[2]], z],
      tsAnalytic[Exp, e[[2]] Log[e[[1]]], z, pcut],   (* base^exp = Exp[exp Log base] *)
    Head[e] === Power, tsPow[e[[1]], e[[2]], z, pcut],
    Head[e] === Log, tsLog[e[[1]], z, pcut],
    MemberQ[{Sin, Cos, Sinh, Cosh, Tan, Tanh, ArcTan, ArcSin, ArcSinh, ArcTanh,
             Cot, Csc, Sec, Coth, Csch, Sech, ArcCos, ArcCsc, ArcSec}, Head[e]],
      tsAnalytic[Head[e], e[[1]], z, pcut],
    True, Message[tsExp::unsup, e]; $Failed]];
tsExp::unsup = "InverseAsymptotic: unsupported subexpression `1`.";

tsPow[base_, e_, z_, pcut_] := Module[{B, c, p, k, S, minexp, jmax, res, Spow, j},
  If[base === z, Return[{{1, e, 0}}]];
  If[FreeQ[base, z], Return[{{base^e, 0, 0}}]];
  If[IntegerQ[e] && e >= 0, Return[tlPowInt[tsExp[base, z, pcut], e, pcut]]];
  B = tsExp[base, z, pcut];
  If[B === $Failed || B === {}, Return[$Failed]];
  {c, p, k} = tlLead[B];
  If[k =!= 0, Message[InverseAsymptotic::leadlog2, base]; Return[$Failed]];
  S = tlSmallPart[B, c, p];
  minexp = If[S === {}, Infinity, Min[N[#[[2]]] & /@ S]];
  jmax = If[S === {} || minexp <= 0, 0, Ceiling[(pcut - p e)/minexp] + 1];
  res = {{c^e, p e, 0}};
  Spow = {{1, 0, 0}};
  Do[
    Spow = tlTimes[Spow, S, pcut - p e];
    res = Join[res, {Binomial[e, j] c^e #[[1]], p e + #[[2]], #[[3]]} & /@ Spow];
    , {j, 1, jmax}];
  tlTrunc[tlCollect[res], pcut]];

tsLog[base_, z_, pcut_] := Module[{B, c, p, k, S, minexp, jmax, res, Spow, j},
  If[base === z, Return[{{1, 0, 1}}]];
  If[FreeQ[base, z], Return[{{Log[base], 0, 0}}]];
  B = tsExp[base, z, pcut];
  If[B === $Failed || B === {}, Return[$Failed]];
  {c, p, k} = tlLead[B];
  If[k =!= 0, Message[InverseAsymptotic::leadlog2, base]; Return[$Failed]];
  S = tlSmallPart[B, c, p];
  minexp = If[S === {}, Infinity, Min[N[#[[2]]] & /@ S]];
  jmax = If[S === {} || minexp <= 0, 0, Ceiling[pcut/minexp] + 1];
  res = {{Log[c], 0, 0}, {p, 0, 1}};
  Spow = {{1, 0, 0}};
  Do[
    Spow = tlTimes[Spow, S, pcut];
    res = Join[res, {(-1)^(j + 1)/j #[[1]], #[[2]], #[[3]]} & /@ Spow];
    , {j, 1, jmax}];
  tlTrunc[tlCollect[res], pcut]];

tsAnalytic[h_, base_, z_, pcut_] := Module[{B, c0, S, minexp, jmax, res, Spow, j, der, ders},
  B = tsExp[base, z, pcut];
  If[B === $Failed, Return[$Failed]];
  c0 = Total[Cases[B, {co_, q_ /; PossibleZeroQ[q], 0} :> co]];
  S = DeleteCases[B, {_, q_ /; PossibleZeroQ[q], 0}];
  If[S =!= {} && Min[N[#[[2]]] & /@ S] <= $tol,
     Message[InverseAsymptotic::notsmall, base]; Return[$Failed]];
  minexp = If[S === {}, Infinity, Min[N[#[[2]]] & /@ S]];
  jmax = If[S === {} || minexp <= 0, 0, Ceiling[pcut/minexp] + 1];
  (* refuse when the argument tends to a singularity of h (Tan->pi/2, Log/Sqrt->0,
     ArcSin->1, ...): h(c0) or any needed derivative is non-finite *)
  ders = Table[D[h[t], {t, j}] /. t -> c0, {j, 0, jmax}];
  If[! FreeQ[ders, DirectedInfinity | ComplexInfinity | Indeterminate] ||
       MemberQ[ders, _Limit],
     Message[InverseAsymptotic::singular, h]; Return[$Failed]];
  res = {{ders[[1]], 0, 0}};
  Spow = {{1, 0, 0}};
  Do[
    Spow = tlTimes[Spow, S, pcut];
    der = ders[[j + 1]];
    res = Join[res, {der/j! #[[1]], #[[2]], #[[3]]} & /@ Spow];
    , {j, 1, jmax}];
  tlTrunc[tlCollect[res], pcut]];
InverseAsymptotic::notsmall =
  "InverseAsymptotic: analytic function of `1`, whose argument does not tend to a \
constant, is outside the supported scale.";
InverseAsymptotic::leadlog2 =
  "InverseAsymptotic: a non-integer power or logarithm of `1` (whose leading term \
carries a logarithm) is outside the supported scale.";

tlToExpr[ml_, z_] := Total[(#[[1]] z^#[[2]] Log[z]^#[[3]]) & /@ ml];

(* ================= leading term & core inversion ===================== *)

(* leading monomial c x^p of fexpr as x -> 0+ (pure power; log-free).
   Returns {c, p} or $Failed (with a reason tag in the second slot). *)
leadingPower[fexpr_, x_] := Quiet[Module[{p, c},
  p = Limit[x D[fexpr, x]/fexpr, x -> 0, Direction -> "FromAbove"];
  If[! TrueQ[NumericQ[N[p]] && Element[N[p], Reals] && N[p] != 0],
     Return[{$Failed, "power"}]];
  c = Limit[fexpr/x^p, x -> 0, Direction -> "FromAbove"];
  (* screen the SYMBOLIC c first (a surviving Log/Limit head, or a non-real /
     non-numeric coefficient, signals a logarithmic or undefined leading term) *)
  If[c === 0 || c === Indeterminate || ! FreeQ[c, DirectedInfinity] ||
     ! FreeQ[c, Log] || ! FreeQ[c, Limit] || ! TrueQ[NumericQ[N[c]]],
     Return[{$Failed, "log"}]];
  {Simplify[c], Simplify[p]}], {Power::infy, Infinity::indet, Power::indet}];

(* contractive fixed point:  X <- ((z - f(X) + c X^p)/c)^(1/p),  z = image var.
   Returns the monomial list; emits ::nconv if it does not stabilize in budget. *)
invertCore[fexpr_, x_, z_, c_, p_, pcut_, maxiter_: 80] := Quiet[Module[
  {X, Xprev, Xprev2, i, ok = False},
  X = {{c^(-1/p), 1/p, 0}};
  Xprev2 = Null;
  Do[
    Xprev2 = Xprev; Xprev = X;
    X = tsExp[((z - (fexpr /. x -> tlToExpr[X, z]) + c tlToExpr[X, z]^p)/c)^(1/p), z, pcut];
    If[X === $Failed, Return[$Failed]];
    (* converged (fixed point) or fell into a 2-cycle of the truncation *)
    If[sameMono[X, Xprev] || (Xprev2 =!= Null && sameMono[X, Xprev2]),
       ok = True; Break[]];
    , {i, maxiter}];
  If[! ok, Message[InverseAsymptotic::nconv, fexpr]];
  X], {Power::infy, Infinity::indet, Power::indet, Divide::infy, General::indet}];

sameMono[a_, b_] := Length[a] === Length[b] &&
  AllTrue[Transpose[{monoSort[a], monoSort[b]}],
    (#[[1, 2]] === #[[2, 2]] && #[[1, 3]] === #[[2, 3]] &&
       PossibleZeroQ[#[[1, 1]] - #[[2, 1]]]) &];
monoSort[m_] := SortBy[m, {N[#[[2]]] &, #[[3]] &}];

(* distinct exponents, grouped by EXACT equality (so incommensurate exponents
   that happen to be numerically close, e.g. a Z-combination m + n Sqrt2 near an
   integer at high order, are never fused), sorted ascending by numeric value *)
distinctExps[X_] := SortBy[Union[#[[2]] & /@ X, SameTest -> (PossibleZeroQ[#1 - #2] &)], N];

(* keep the first nlevels distinct power-levels of a monomial list (all log terms
   per level kept together -- never split an equal-exponent group).
   Returns {monomials, remainderExponent}. *)
truncLevels[ml_, nlevels_] := Module[{exps, cutoff},
  exps = distinctExps[ml];
  cutoff = If[Length[exps] > nlevels, exps[[nlevels + 1]],
              If[ml === {}, 0, Max[#[[2]] & /@ ml] + 1]];   (* keep exact *)
  {Select[ml, N[#[[2]]] < N[cutoff] - $tol &], cutoff}];

(* invert to the first nlevels distinct power-levels.
   Returns {monomials, remainderExponent}. *)
invertLevels[fexpr_, x_, z_, c_, p_, nlevels_] := Module[
  {pcut, X, step},
  step = If[NumericQ[N[p]] && N[p] != 0, Abs[1/p], 1];
  pcut = N[1/p] + (nlevels + 3) step;
  X = $Failed;
  Do[
    X = invertCore[fexpr, x, z, c, p, pcut];
    If[X =!= $Failed && Length[distinctExps[X]] > nlevels, Break[]];
    pcut += (nlevels + 3) step;
    , {7}];
  If[X === $Failed, Return[$Failed]];
  truncLevels[X, nlevels]];

(* ================= point / image normalization ======================= *)

Options[InverseAsymptotic] = {
  "At" -> 0, Direction -> "FromAbove", "ImagePoint" -> Automatic,
  "Remainder" -> True, "Verify" -> True, "VerificationTolerance" -> 10^-18};
Options[InverseAsymptoticData] = Options[InverseAsymptotic];

(* core worker: returns the diagnostics Association or $Failed *)
iaWork[fexpr_, x_, y_, nlev_, opts_List] := Module[
  {a, dir, imgOpt, t, sub, g, b, infImg, aInf, G0, lp, c, p, sigma, branches,
   redInv, mono, monoFull, maxE, recip, xfull, xmono, cutoff, emit, side},
  a = "At" /. opts; dir = Direction /. opts; imgOpt = "ImagePoint" /. opts;
  aInf = MemberQ[{Infinity, -Infinity, DirectedInfinity[1], DirectedInfinity[-1]}, a];
  (* local var t -> 0+,  x = sub(t) *)
  Which[
    a === Infinity || a === DirectedInfinity[1], sub = 1/t,
    a === -Infinity || a === DirectedInfinity[-1], sub = -1/t,
    True, sub = a + If[dir === "FromBelow" || dir === -1, -1, 1] t];
  g = fexpr /. x -> sub;
  b = If[imgOpt === Automatic,
        Quiet@Limit[g, t -> 0, Direction -> "FromAbove"], imgOpt];
  infImg = (b === Infinity || b === -Infinity || ! FreeQ[b, DirectedInfinity]);
  (* reduced function G0(t) -> 0+ as t -> 0+; image map z -> (image of y) *)
  G0 = If[infImg, 1/g, g - b];
  lp = leadingPower[G0, t];
  If[MatchQ[lp, {$Failed, _}],
    If[lp[[2]] === "log", Message[InverseAsymptotic::leadlog, fexpr],
       Message[InverseAsymptotic::nolead, fexpr]];
    Return[$Failed]];
  {c, p} = lp;
  sigma = Sign[c];
  (* sigma must resolve to +-1; for an infinite image, sigma encodes which side
     (sigma < 0 means the image tends to -Infinity, not supported here) *)
  If[! MatchQ[sigma, 1 | -1],
     Message[InverseAsymptotic::nolead, fexpr]; Return[$Failed]];
  If[infImg && sigma < 0, Message[InverseAsymptotic::badside]; Return[$Failed]];
  (* even leading order -> the real inverse is two-valued (the opposite Direction
     gives the other branch to the same image side) *)
  branches = If[IntegerQ[p] && EvenQ[p], 2, 1];
  If[branches == 2,
     Message[InverseAsymptotic::branches, p,
        If[dir === "FromBelow" || dir === -1, "\"FromBelow\"", "\"FromAbove\""]]];
  (* invert  sigma*G0(t) == zz  (positive leading coef -> real positive zz seed),
     carrying everything through the monomial engine to a clean emission. *)
  If[aInf,
    (* reciprocal regime: x = (+-1)/t, build full x-series then level-truncate *)
    redInv = invertLevels[sigma G0, t, zz, sigma c, p, nlev + 4];
    If[redInv === $Failed, Return[$Failed]];
    monoFull = redInv[[1]];
    maxE = Max[N[#[[2]]] & /@ monoFull];
    recip = If[a === -Infinity || a === DirectedInfinity[-1], -1, 1]/tlToExpr[monoFull, zz];
    xfull = tsExp[recip, zz, maxE];
    If[xfull === $Failed, Return[$Failed]];
    {xmono, cutoff} = truncLevels[tlCollect[xfull], nlev],
   (* finite a: x = a + dir*t, dir-signed corrections plus the constant a *)
    redInv = invertLevels[sigma G0, t, zz, sigma c, p, nlev];
    If[redInv === $Failed, Return[$Failed]];
    {mono, cutoff} = redInv;
    xmono = tlCollect[Join[
       If[PossibleZeroQ[a], {}, {{a, 0, 0}}],
       {If[dir === "FromBelow" || dir === -1, -1, 1] #[[1]], #[[2]], #[[3]]} & /@ mono]]];
  (* emit: zz -> image variable in y *)
  emit = emitMonomials[xmono, y, b, sigma, infImg];
  side = Which[
    infImg, "y -> " <> If[sigma > 0, "+", "-"] <> "Infinity",
    PossibleZeroQ[b], "y -> 0" <> If[sigma > 0, "+", "-"],
    True, "y -> " <> ToString[b, InputForm] <> If[sigma > 0, "+", "-"]];
  <|"Expansion" -> emit, "Monomials" -> xmono,
    "LeadingPower" -> {c, p}, "ImagePoint" -> b, "Side" -> side,
    "RemainderExponent" -> cutoff, "InfiniteImage" -> infImg, "Sigma" -> sigma,
    "RealBranches" -> branches|>];

(* Turn x-monomials (in the positive infinitesimal zz) into an expression in y,
   grouped by power level so each power carries a single Log-polynomial coefficient
   (reads like  y + (-1 - Log[y]) y^2 + ...  rather than a spread-out sum).
     finite b:           zz = sigma (y - b),  emit in w = sigma(y - b)
     infinite b (sigma>0): zz = 1/y,  zz^p = y^-p,  Log[zz] = -Log[y] *)
emitMonomials[xmono_, y_, b_, sigma_, infImg_] := Module[{w, lg, groups},
  If[infImg, w = 1/y; lg = -Log[y], w = If[sigma > 0, y - b, b - y]; lg = Log[w]];
  groups = GatherBy[xmono, #[[2]] &];
  Total[Function[grp,
     Collect[Total[(#[[1]] lg^#[[3]]) & /@ grp], Log[_]] *
       (If[infImg, y^(-grp[[1, 2]]), w^grp[[1, 2]]])] /@ groups]];

(* ================= numeric verification ============================== *)
(* Correct asymptotic check: the back-substitution residual r(d) = f(X(y)) - y,
   with d the positive infinitesimal (|y-b| finite, or 1/|y| infinite), must
   DECAY at least like d^cutoff as d -> 0.  We measure the empirical decay
   exponent across THREE shrinking samples (requiring both consecutive slopes to
   reach the order) and compare to the remainder exponent; a fixed absolute
   tolerance would wrongly flag a low-order truncation, so the absolute branch is
   reserved as an EXACT floor (a genuinely exact inverse has a vanishing residual).
   Note: the broad N::meprec etc. are deliberately NOT silenced here, so a
   precision failure in the check surfaces rather than masquerading as a pass. *)
verifyExpansion[fexpr_, x_, y_, assoc_, tol_] :=
 Quiet[Block[{$MaxExtraPrecision = 600},
  Module[{b, sigma, infImg, expr, cutoff, maxLogK, slack, ds, samples, resids,
          slopes, measured, residAt, pos},
    b = assoc["ImagePoint"]; sigma = assoc["Sigma"]; infImg = assoc["InfiniteImage"];
    expr = assoc["Expansion"]; cutoff = assoc["RemainderExponent"];
    (* slack grows with the largest Log-power present: logs depress the apparent
       decay exponent at finite samples *)
    maxLogK = Max[Append[#[[3]] & /@ assoc["Monomials"], 0]];
    slack = 0.4 + 0.3 maxLogK;
    ds = {1/10^3, 1/10^5, 1/10^7};                  (* shrinking infinitesimals *)
    samples = If[infImg, sigma/ds, b + sigma ds];   (* image points on valid side *)
    residAt[yv_] := Module[{xa}, xa = expr /. y -> yv;
      N[Abs[(fexpr /. x -> xa) - yv], 30]];
    resids = residAt /@ samples;
    pos = AllTrue[resids, Positive];
    slopes = If[! pos, {Infinity},
      Table[N[Log[resids[[i + 1]]/resids[[i]]]/Log[ds[[i + 1]]/ds[[i]]]],
        {i, Length[ds] - 1}]];
    measured = Min[slopes];
    (* pass if every consecutive slope reaches cutoff - slack, OR the residual is
       at the exact floor (a truly exact inverse), but NOT merely "small" *)
    {TrueQ[measured >= N[cutoff] - slack] || Max[resids] < tol,
     Max[resids], measured}]],
  {Power::infy, Infinity::indet, Power::indet, Divide::infy, General::indet}];

(* ================= public API ======================================== *)

InverseAsymptotic[fexpr_, x_Symbol, y_Symbol, nlev_Integer, opts : OptionsPattern[]] :=
  Module[{assoc},
    assoc = InverseAsymptoticData[fexpr, x, y, nlev, opts];
    If[! AssociationQ[assoc], Return[$Failed]];
    If[TrueQ[OptionValue["Remainder"]],
       assoc["Expansion"] + remainderTerm[assoc, y],
       assoc["Expansion"]]];

(* sugar: the expansion point as a rule, InverseAsymptotic[f, x -> a, y, n] *)
InverseAsymptotic[fexpr_, (Rule | RuleDelayed)[x_Symbol, a_], y_Symbol, nlev_Integer,
   opts : OptionsPattern[]] := InverseAsymptotic[fexpr, x, y, nlev, "At" -> a, opts];
InverseAsymptoticData[fexpr_, (Rule | RuleDelayed)[x_Symbol, a_], y_Symbol, nlev_Integer,
   opts : OptionsPattern[]] := InverseAsymptoticData[fexpr, x, y, nlev, "At" -> a, opts];

InverseAsymptoticData[fexpr_, x_Symbol, y_Symbol, nlev_Integer, opts : OptionsPattern[]] :=
  Module[{ov, assoc, ver, tol},
    ov = Flatten[{opts, Options[InverseAsymptotic]}];
    assoc = iaWork[fexpr, x, y, nlev, ov];
    If[! AssociationQ[assoc], Return[$Failed]];
    tol = "VerificationTolerance" /. ov;
    If[TrueQ["Verify" /. ov],
      ver = verifyExpansion[fexpr, x, y, assoc, tol];
      assoc = Join[assoc, <|"Verified" -> ver[[1]], "MaxResidual" -> ver[[2]],
                            "MeasuredOrder" -> ver[[3]]|>];
      If[! TrueQ[ver[[1]]],
         Message[InverseAsymptotic::verify, ver[[3]], assoc["RemainderExponent"]]]];
    assoc];

(* remainder term as BigO in the natural variable *)
remainderTerm[assoc_, y_] := Module[{b, sigma, infImg, cut, v},
  b = assoc["ImagePoint"]; sigma = assoc["Sigma"];
  infImg = assoc["InfiniteImage"]; cut = assoc["RemainderExponent"];
  Which[
    infImg, BigO[y, -cut],
    PossibleZeroQ[b], BigO[If[sigma > 0, y, -y], cut],
    True, BigO[If[sigma > 0, y - b, b - y], cut]]];

(* display of the inert order term *)
BigO /: MakeBoxes[BigO[v_, p_], StandardForm] :=
  RowBox[{"O", "(", MakeBoxes[v^p, StandardForm], ")"}];
BigO /: MakeBoxes[BigO[v_, p_], TraditionalForm] :=
  RowBox[{"O", "(", MakeBoxes[v^p, TraditionalForm], ")"}];
(* plain-text contexts (OutputForm / InputForm / Print) read O(v^p) too *)
Format[BigO[v_, p_], OutputForm] := SequenceForm["O(", v^p, ")"];

End[];
EndPackage[];
