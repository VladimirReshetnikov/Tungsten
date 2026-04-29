---
abstract: |
  The purpose of this paper is to present the details of an arithmetic system which virtually abolishes the phenomena of computer overflow and underflow in a logically symmetric manner. A generalized exponential function is used in such a way as to enable very large numbers to be represented with a uniform precision, and very small numbers by reciprocation.
author:
- |
  C. W. Clenshaw and P. R. Turner\
  Department of Mathematics, University of Lancaster, Lancaster LA1 4YL, UK\
  Dedicated to Professor Leslie Fox on the occasion of his seventieth birthday
title: The Symmetric Level-Index System
---

# 1. Introduction

In this paper we discuss in detail the symmetric version of the level-index (li) number system and its arithmetic. The li system was introduced by Clenshaw & Olver (1984) and the algorithms for li arithmetic were presented by the same authors (1987). This 1987 paper, an essential introduction to the present work, is henceforth referred to as ’AO’, the abbreviation signifying ’arithmetic operations’. In both those papers, mention was made of an extension of the system which allows a small number to be represented to high precision by storing its reciprocal in li form, together with an indicator to show that this is indeed a reciprocal.

Thus, for the symmetric level index (sli) system, we may represent a nonzero real number $`X`$ by another number $`x`$ together with two signs $`\mathrm{s}(X)`$ and $`\mathrm{r}(X)`$. The relation between these quantities is

``` math
\begin{equation*}
X=\mathrm{s}(X) \phi(x)^{\mathrm{r}(X)}, \tag{1}
\end{equation*}
```

where $`\mathrm{s}(X)=\operatorname{sgn} X`$,

``` math
r(X)= \begin{cases}+1 & \text { if }|X| \geqslant 1, \\ -1 & \text { if }|X|<1,\end{cases}
```

and $`\phi`$ is the generalized exponential function used by Clenshaw & Olver $`(1984,1987)`$ for the ordinary li representation. This is defined for nonnegative arguments by

``` math
\phi(x)= \begin{cases}x & \text { if } 0 \leqslant x \leqslant 1, \\ \exp \phi(x-1) & \text { if } x>1 .\end{cases}
```

There are several possible implementations of this representation, depending on how the (now redundant) level zero is used. One option is to permit the use of levels 1 to 8 instead of 0 to 7 ; another to retain level zero for special purposes. There is also redundancy in the representation of $`\pm 1`$ (since $`\phi(1)=1 / \phi(1)`$ ). This could be used for a special representation of zero.

An alternative representation function for sli numbers which was introduced in AO uses the mapping $`X=\mathrm{s}(X) \Phi(x)`$. Here $`|X|=\Phi(x)`$, where

``` math
\Phi(x)= \begin{cases}\phi(1+x) & \text { if } x \geqslant 0 \\ 1 / \phi(1-x) & \text { if } x<0\end{cases}
```

and $`\mathrm{s}(X)`$ is still $`\operatorname{sgn} X`$. The two representations are essentially similar and we shall use whichever is convenient.

It is obvious that sli arithmetic can be performed merely by using the li algorithms; but this is likely to be unnecessarily time-consuming since, for example, to compute the sum of two small numbers by the relation

``` math
\frac{1}{\phi(x)}+\frac{1}{\phi(y)}=\frac{\phi(x)+\phi(y)}{\phi(x) \phi(y)}
```

requires three li operations. It is also likely to be less satisfactory because the computation of the sum and product will be based on the larger of $`x`$ and $`y`$, that is, on the less significant summand.

For these two reasons, we describe (in Section 2) algorithms for sli arithmetic which use the same basic approach as the li operations but work directly with the sli representation; the primary objective being to provide sli algorithms which are as fast to execute as those for li arithmetic. In Section 3, we discuss briefly the first-order error analysis of these algorithms, from which we see that appropriate precision can be preserved in a similar way to that of the li system.

For the sli system to be a useful computing facility, an efficient hardware/software implementation is required. The same considerations apply here as to the li system, for which some approaches to practical implementation are discussed by Turner (1985). It is also necessary that the system be seen to be useful in application. Clenshaw & Turner (1988) give an indication of this usefulness and demonstrate that the appropriate degree of precision is retained in the very large and very small numbers generated, so that useful information is obtained as the end-product. This point is discussed in more detail by Lozier & Olver (1988).

# 2. Algorithms for sli arithmetic

One of the main advantages of the sli system, compared with li, lies in the fact that the absence of level zero removes many of the special cases. An extra difficulty which is introduced is the occasional need for ’flip-over’ between reciprocal and standard form: this happens, for example, when

``` math
\phi(x)-\phi(y)<1 \quad \text { or } \quad \frac{1}{\phi(x)}+\frac{1}{\phi(y)} \geqslant 1
```

so that the reciprocation sign of the answer is different from that of the operands. However, all such cases are easily identified and dealt with.

We begin the discussion of arithmetic algorithms with addition and subtraction; that is, we must find

``` math
Z=\mathrm{s}(Z) \phi(z)^{\mathrm{r}(Z)}=X \pm Y=\mathrm{s}(X) \phi(x)^{\mathrm{r}(X)} \pm \mathrm{s}(Y) \phi(y)^{\mathrm{r}(Y)}
```

We assume throughout the rest of this discussion that

``` math
\mathrm{s}(Z)=\mathrm{s}(X)=\mathrm{s}(Y)=+1 \quad \text { and } \quad X \geqslant Y .
```

(The sorting of signs, including the operation sign, and the ordering of the arguments, is a necessary preliminary step to the algorithms. We do not discuss these details here.) There are therefore three situations to consider, namely:

``` math
\mathrm{r}(X)=\mathrm{r}(Y)=+1, \quad \mathrm{r}(X)=+1=-\mathrm{r}(Y), \quad \mathrm{r}(X)=\mathrm{r}(Y)=-1 .
```

These are referred to, respectively, as ’large’, ’mixed’, and ’small’ arithmetic. It should also be noted that in all cases we have

``` math
x, y, z \geqslant 1
```

For large arithmetic, the algorithms use the sequences $`\left\{a_{j}\right\},\left\{b_{j}\right\}`$, and $`\left\{c_{j}\right\}`$ of the original li operations; thus

``` math
a_{j}=1 / \phi(x-j), \quad b_{j}=\phi(y-j) / \phi(x-j), \quad c_{j}=\phi(z-j) / \phi(x-j) .
```

For mixed and for small arithmetic, we still use $`\left\{a_{j}\right\}`$ and $`\left\{c_{j}\right\}`$. However, the sequence $`\left\{b_{j}\right\}`$ is replaced by $`\left\{\alpha_{j}\right\}`$ in the mixed case, and $`\left\{\beta_{j}\right\}`$ in the small case, where

``` math
\alpha_{j}=1 / \phi(y-j), \quad \beta_{j}=\phi(x-j) / \phi(y-j) .
```

In some situations, it is also necessary to compute elements of the sequence $`\left\{h_{j}\right\}`$, where

``` math
h_{j}=\phi(z-j)
```

just as in li arithmetic when division is performed with a level-zero denominator, for example.

Throughout the subsequent description, we denote the integer and fractional parts of $`x`$ by $`l`$ and $`f`$ respectively, and those of $`y`$ by $`m`$ and $`g`$.

Note that $`x \geqslant y`$ for large arithmetic, while $`x \leqslant y`$ in the case of small arithmetic. The subtraction of two equal numbers would of course be identified as a special case. We thus assume henceforth that $`X>Y`$. (The algorithm remains valid for $`X+X`$, but this too can be treated separately since then either $`b_{0}=1`$ or $`\beta_{0}=1`$.)

The algorithm for addition or subtraction proceeds as follows:\
Step 1. Set $`\mathrm{r}(Z):=\mathrm{r}(X)`$.\
Step 2. Compute

``` math
a_{l-1}:=\mathrm{e}^{-f}, \quad a_{j-1}:=\exp \left(-1 / a_{j}\right) \quad(j=l-1, l-2, \ldots, 1)
```

in parallel with

<div class="center">

|  |  |  |
|:---|:--:|:--:|
| If $`\mathrm{r}(X)=\mathrm{r}(Y)=1:`$ | if $`\mathrm{r}(X)=1`$ and $`\mathrm{r}(Y)=-1:`$ | if $`\mathrm{r}(X)=\mathrm{r}(Y)=-1:`$ |
| $`b_{m-1}:=a_{m-1} \mathrm{e}^{g}`$, | $`\alpha_{m-1}:=\mathrm{e}^{-g}`$, | $`\beta_{l-1}:=\exp \left[f-\exp ^{(m-l)} g\right]`$, |
| $`b_{j-1}:=\exp \left[\left(b_{j}-1\right) / a_{j}\right]`$ | $`\alpha_{j-1}:=\exp \left(-1 / \alpha_{j}\right)`$ | $`\beta_{j-1}:=\exp \left[\left(\beta_{j}-1\right) / a_{j} \beta_{j}\right]`$ |
| $`(j=m-1, m-2, \ldots, 1)`$, | $`(j=m-1, m-2, \ldots, 1)`$, | $`(j=l-1, l-2, \ldots, 1)`$, |
| $`c_{0}^{\prime \prime}:=1 \pm b_{0} ;`$ | $`c_{0}^{\prime \prime}:=1 \pm a_{0} \alpha_{0} ;`$ | $`c_{0}^{\prime}:=1 \pm \beta_{0}`$. |

</div>

Step 3. If $`c_{0}^{\prime \prime}<a_{0}`$ then

``` math
\begin{aligned}
& \mathrm{r}(Z):=-1, \\
& h_{1}:=-\ln \left(c_{0}^{\prime \prime} / a_{0}\right), \\
& \text { go to step } 5 ; \\
& \text { else if } l=1 \text { then } h_{1}:=f+\ln c_{0}^{\prime \prime}, \\
& \text { go to step } 5 ; \\
& \text { else } c_{1}:=1+a_{1} \ln c_{0}^{\prime \prime} ;
\end{aligned}
```

if $`a_{0} c_{0}^{\prime}>1`$ then set\
$`\mathrm{r}(Z):=1`$,\
$`z:=1+\ln \left(a_{0} c_{0}^{\prime}\right)`$,\
finish;\
else if $`l=1`$ then $`h_{1}:=f-\ln c_{0}^{\prime}`$, go to step 5 ;\
else $`c_{1}:=1-a_{1} \ln c_{0}^{\prime}`$;

Step 4. For $`j=1, \ldots, l-2`$ :

``` math
\begin{array}{cc}
\text { if } c_{j}<a_{j} & \begin{array}{c}
\text { then } z:=j+c_{j} / a_{j}, \text { finish; } \\
\text { else } c_{j+1}:=1+a_{j+1} \ln c_{j} ;
\end{array} \\
\text { if } c_{l-1}<a_{l-1} & \text { then } z:=l-1+c_{l-1} / a_{l-1}, \text { finish; } \\
\text { else } h_{l}:=f+\ln c_{l-1} .
\end{array}
```

Step 5. Compute $`h_{j}:=\ln h_{j-1}`$ until $`h_{j} \in[0,1)`$ in which case

``` math
z:=j+h_{j} .
```

Notes. (i) In the case of ’small’ arithmetic, the computation of $`\beta_{l-1}`$ may require (when $`m>l`$ ) the computation of

``` math
\alpha_{m-1}:=\mathrm{e}^{-g}, \quad \alpha_{j-1}:=\exp \left(-1 / \alpha_{j}\right) \quad(j=m-1, \ldots, l),
```

in order to obtain $`\beta_{l-1}:=\alpha_{l-1} / a_{l-1}`$. This still requires just one sequence of length $`l`$ and one of length $`m`$ in order to obtain $`c_{0}^{\prime}`$.

A somewhat simpler relation for the sequence $`\left\{\beta_{j}\right\}`$ is

``` math
\beta_{j-1}:=\exp \left[\left(\beta_{j}-1\right) / \alpha_{j}\right]
```

which corresponds precisely to the defining relation for $`\left\{b_{j}\right\}`$. This necessitates the computation of the full sequence $`\left\{\alpha_{j}\right\}`$, as well as $`\left\{a_{j}\right\}`$, first. In an environment where these can be computed in parallel (or if several sli operations are being performed in parallel on a machine such as the ICL DAP), this simpler relation may be preferred. However, greater care is then needed over the precisions of the various quantities, since this has the effect of basing the computation on the smaller operand $`1 / \phi(y)`$ which complicates the error analysis.\
(ii) The various cases of ’flip-over’ are easily identified in step 3 and handled using (repeated) logarithms.\
(iii) In the ordinary li algorithms, a test is made so that, if (the computed value of) $`a_{0}`$ is zero, then $`z=x`$. Similar provisos are useful here. For mixed arithmetic we set $`z=x`$ if $`\alpha_{0}=0`$, while for small arithmetic the condition $`\beta_{0}=0`$ is used.\
(iv) In the cases of large or mixed addition and small subtraction, we know that $`c_{j} \geqslant a_{j}(j=1, \ldots, l-1)`$ and so the testing implied by step 4 is unnecessary in these instances. It is included in the algorithm for the sake of compactness.\
(v) All the internal calculation can be in fixed-point arithmetic, since the\
various quantities remain suitably bounded. In all cases, we have

``` math
0 \leqslant a_{j}, b_{j}, \alpha_{j}, \beta_{j} \leqslant 1,
```

while $`0 \leqslant c_{j} \leqslant 2`$ except possibly for small subtraction. For this exceptional case, we have $`c_{0}^{\prime} \geqslant \gamma`$, where $`\gamma`$ is the working precision being used, from which it follows that $`c_{1}=1-a_{1} \ln c_{0}^{\prime} \leqslant 1+\ln 1 / \gamma`$. A similar bound applies for $`h_{l}`$ whenever it is computed, while for large or mixed subtraction with $`c_{0}<a_{0}`$

``` math
h_{1}=\ln a_{0} / c_{0} \leqslant \ln 1 / c_{0} \leqslant \ln 1 / \gamma .
```

\(vi\) For extended sums, savings can be made in much the same way as in $`\mathrm{AO}(\S 2.5)`$. Only one sequence $`\left\{a_{j}\right\}`$ is needed, and any $`\left\{b_{j}\right\}`$ and $`\left\{\alpha_{j}\right\}`$ (or $`\left\{\beta_{j}\right\}`$ ) can be computed in parallel to produce a single $`c_{0}^{\prime \prime}`$ (or $`c_{0}^{\prime}`$ ).

The multiplication and division of sli numbers are easily described, since all the various cases are equivalent to operations which involve only numbers greater than unity together with the appropriate reciprocation signs; specifically:

``` math
\begin{aligned}
& \phi(x) \phi(y)=\left[\phi(x)^{-1} \phi(y)^{-1}\right]^{-1}=\phi(x) / \phi(y)^{-1}=\left[\phi(x)^{-1} / \phi(y)\right]^{-1} \\
& \phi(x) / \phi(y)=\phi(x) \phi(y)^{-1}=\left[\phi(x)^{-1} \phi(y)\right]^{-1}=\left[\phi(x)^{-1} / \phi(y)^{-1}\right]^{-1} .
\end{aligned}
```

Thus we may suppose $`X \geqslant Y \geqslant 1`$ and consider just $`X Y`$ and $`X / Y`$, which are readily dealt with using the ordinary li algorithms for

``` math
\ln X \pm \ln Y=\phi(x-1) \pm \phi(y-1)
```

(or, equivalently, by setting $`c_{1}=1 \pm b_{1}`$ in the above algorithm with minor modification for the case $`m=1`$ ). Comparison with AO highlights the simplicity which the symmetric representation allows.

The exponentiation operation does, however, require some use of the ordinary li division and multiplication algorithms in situations such as raising a large number to a small power; that is,

``` math
Z=\phi(z)^{\mathrm{r}(Z)}=X^{Y}=\phi(x)^{\phi(y)^{-1}}
```

Then $`\mathrm{r}(Z)=1`$ and

``` math
\ln Z=\phi(z-1)=\phi(y)^{-1} \phi(x-1)
```

so that, if $`y>x-1`$, the sli operation would compute the right-hand side as $`[\phi(y) / \phi(x-1)]^{-1}`$. What is required is the level-zero result of the li operation $`\phi(x-1) / \phi(y)=h`$ (say), from which we obtain $`z=1+h`$. It is important to note here that the li division algorithm can be significantly simplified, since $`y \geqslant 1`$ and so division by a level-zero number is never needed.

# 3. Error control

In this section we confirm, by means of linearized error analysis, that the errors resulting from the above algorithms can be restricted to the order of inherent error. This is achieved by working to fixed absolute precisions in the computation of the various sequences. The implications of the analysis on the choice of working precisions are discussed briefly in the final section of the paper.

We adopt here the same notation as in AO (§3.2); thus we assume that the sequence $`\left\{a_{j}\right\}`$ is stored with absolute precision $`\gamma_{1}`$ while all the other quantities are stored to absolute precision $`\gamma`$. We also assume that the various special functions involved are computed to these same precisions. However, it should be noted that, especially in the case of $`\left\{\beta_{j}\right\}`$, considerable care will be needed in the implementation. In order to evaluate $`\exp \left[\left(\beta_{j}-1\right) / a_{j} \beta_{j}\right]`$ with absolute precision $`\gamma`$, it will not suffice to compute the product $`a_{j} \beta_{j}`$ to this same precision. Similar considerations for the sequence $`\left\{c_{j}\right\}`$ led, in AO , to the greater precision requirement for the sequence $`\left\{a_{j}\right\}`$.

In performing a first-order error analysis for the sli algorithms, there are nine cases to consider, but most of these are straightforward extensions of the li theory in AO. Two of these cases, namely ’large’ addition and subtraction where the result is at least unity are of course identical to the li results without the need to consider the special cases arising from level-zero operands or answers.

For subtraction where the result is in reciprocal form, that is, where we have $`x-y \geqslant \gamma`$ and

``` math
\phi(x)-\phi(y)=1 / \phi(z)
```

the inherent error given by linear perturbation theory is

``` math
\delta z=-\frac{\phi^{\prime}(x) \phi(z)}{\phi^{\prime}(z-1)} \delta x+\frac{\phi^{\prime}(y) \phi(z)}{\phi^{\prime}(z-1)} \delta y
```

where we have used the fact (cf. AO, eqn 3.2) that

``` math
\frac{\phi(z)^{2}}{\phi^{\prime}(z)}=\frac{\phi(z)^{2}}{\phi(z) \phi^{\prime}(z-1)}=\frac{\phi(z)}{\phi^{\prime}(z-1)}
```

The analysis of this case is precisely the same as that for ordinary li subtraction as far as the computation of $`c_{0} / a_{0}=h_{0}^{\prime}(\mathrm{say})`$. (This is the $`h`$ of AO (eqn 2.15) in the case $`n=0`$.) Then, for $`j=0,1, \ldots`$, we have

``` math
\left|\delta h_{j+1}\right| \leqslant \frac{1}{h_{j}}\left|\delta h_{j}\right|+\gamma \leqslant \gamma\left(1+\frac{1}{h_{j}}+\cdots+\frac{1}{h_{j} \cdots h_{1}}\right)+\frac{1}{h_{j} \cdots h_{1} h_{0}}\left|\delta h_{0}^{\prime}\right|
```

Now $`1 / h_{0}^{\prime}=\phi(z)`$ and $`h_{j}=\phi(z-j)(j=1,2, \ldots)`$, so that, using AO (eqn 3.17), we have

``` math
\begin{equation*}
\left|\delta h_{j+1}\right| \leqslant \rho \gamma+\frac{\phi(z)}{\phi^{\prime}(z-1)}\left|\delta h_{0}^{\prime}\right| \tag{3.1}
\end{equation*}
```

(as in AO, $`\rho`$ denotes the sum $`1+\frac{1}{\phi^{\prime}(1)}+\frac{1}{\phi^{\prime}(2)}+\cdots=2 \cdot 3921`$ ).\
The first part of the following technical lemma establishes that

``` math
1 \leqslant \phi(z) / \phi^{\prime}(z-1)
```

and so the bounds obtained in AO (§3.4) adapted to the special case $`n=0`$ yield

``` math
\begin{equation*}
|\delta z| \leqslant\left[(2 \rho+1) \gamma+\lambda \gamma_{1}\left(1+\frac{\rho}{\mathrm{e}}\right)\right] \frac{\phi(z) \phi^{\prime}(x)}{\phi^{\prime}(z-1)} \tag{3.2}
\end{equation*}
```

where $`\lambda`$, as in AO (eqn 3.14), $`\lambda=\left(4+\mathrm{e}^{2}\right) \mathrm{e}^{-\mathrm{e}}+1=1 \cdot 7515 \ldots`$.\
Lemma 3.1 (i) The function $`\theta`$, given by

``` math
\theta(z)=\phi(z) / \phi^{\prime}(z-1)
```

is increasing for $`z>1`$, and $`\theta(1)=1`$.\
(ii) For $`1 \leqslant j \leqslant z-1`$ and $`\phi(z) \geqslant \mathrm{e}^{2}`$, the quantity $`\theta(z-j) / \theta(z)`$ is a decreasing function of $`z`$.\
Proof. Now $`\theta(1)=\phi(1) / \phi^{\prime}(0)=1`$ and

``` math
\theta^{\prime}(z)=\frac{\phi^{\prime}(z)}{\phi^{\prime}(z-1)}-\frac{\phi(z) \phi^{\prime \prime}(z-1)}{\phi^{\prime}(z-1)^{2}}=\phi(z)\left(1-\frac{\phi^{\prime \prime}(z-1)}{\phi^{\prime}(z-1)^{2}}\right)
```

If $`n=\lfloor z\rfloor=1`$, then $`\phi^{\prime \prime}(z-1)=0`$, so that $`\theta^{\prime}(z)>0`$; while, for $`n \geqslant 2`$, we have

``` math
\phi^{\prime \prime}(z-1)=\phi^{\prime}(z-1) \sum_{j=2}^{n} \phi^{\prime}(z-j)
```

so that

``` math
\frac{\phi^{\prime \prime}(z-1)}{\phi^{\prime}(z-1)^{2}}=\frac{\sum_{j=2}^{n} \phi^{\prime}(z-j)}{\phi^{\prime}(z-1)} \leqslant \frac{n-1}{\phi(z-1)} \leqslant \frac{n-1}{\phi(n-1)}<1
```

which again yields $`\theta^{\prime}(z)>0`$ and completes the proof of (i). Similar arguments can be used to establish (ii).

The analyses of the ’mixed’ operations, with result greater than unity, are again simple modifications of the ordinary li cases, and the only changes result from the use of the $`\left\{\alpha_{j}\right\}`$ sequence. We obtain for the addition $`\phi(x)+1 / \phi(y)=\phi(z)`$ the bound

``` math
\begin{equation*}
|\delta z| \leqslant(\rho+\lambda+3) \gamma+(\rho \ln 1 / \gamma+1) \lambda \gamma_{1} \tag{3.3}
\end{equation*}
```

while for $`\phi(x)-1 / \phi(y)=\phi(z)`$ we have

``` math
\begin{equation*}
|\delta z| \leqslant\left[(\rho+\lambda+1) \gamma+(\rho \ln 1 / \gamma+1) \lambda \gamma_{1}\right] \phi^{\prime}(x) / \phi^{\prime}(z) \tag{3.4}
\end{equation*}
```

For the case where this subtraction has a result less than unity, we require $`z`$ such that

``` math
\phi(x)-1 / \phi(y)=1 / \phi(z)
```

Here the analysis is simplified by the fact that $`\phi(x) \in[1,2)`$, so that $`l=1`$ and $`\phi(x)=\phi^{\prime}(x)`$. This yields $`\left|\delta c_{0}\right| \leqslant \gamma_{1}+(\lambda+1) \gamma`$, from which, using (3.1), we obtain the required bound in the form

``` math
\begin{equation*}
|\delta z| \leqslant\left[(\lambda+\rho+2) \gamma+2 \gamma_{1}\right] \frac{\phi(x) \phi(z)}{\phi^{\prime}(z-1)} \tag{3.5}
\end{equation*}
```

In the common cases of ’small’ arithmetic where

``` math
\frac{1}{\phi(x)} \pm \frac{1}{\phi(y)}=\frac{1}{\phi(z)}
```

the inherent error given by linear perturbation theory satisfies

``` math
\frac{\phi^{\prime}(z-1)}{\phi(z)} \delta z=\frac{\phi^{\prime}(x-1)}{\phi(x)} \delta x \pm \frac{\phi^{\prime}(y-1)}{\phi(y)} \delta y
```

Here $`x \leqslant y`$, and so from Lemma 3.1 we see that the first term on the right hand side dominates; that is,

``` math
|\delta z| \simeq \frac{\phi^{\prime}(x-1) \phi(z)}{\phi^{\prime}(z-1) \phi(x)}|\delta x|
```

The essential distinguishing feature in the analysis of ’small’ arithmetic results from analysing the sequence $`\left\{\beta_{j}\right\}`$.

From this we obtain

``` math
\left|\delta \beta_{0}\right| \leqslant \frac{\phi^{\prime}(y-1)}{\phi(y)} \phi(x)\left(\frac{A \lambda \gamma_{1}}{\mathrm{e}}+B \gamma+K \frac{\phi(y-l+1)}{\phi^{\prime}(y-l) \phi(x-l+1)}\right),
```

where

``` math
A=\sum_{j=0}^{l-2} \frac{\phi(y-j)}{\phi^{\prime}(y-j-1)} \frac{\phi(x-j-1)}{\phi(x-j)}, \quad B=\sum_{j=0}^{l-2} \frac{\phi(y-j)}{\phi^{\prime}(y-j-1) \phi(x-j)},
```

and $`K=\mathrm{e}\left(\lambda \gamma+\gamma_{1}\right)+\gamma`$.\
Now Lemma 3.1 shows that, for fixed $`x`$, the above bound decreases as $`y`$ increases. Since $`y \geqslant x`$ and $`\lfloor x\rfloor=l`$, it follows that $`A \leqslant \rho`$ and $`B \leqslant \rho-1`$, and Lemma 3.1 gives

Hence

``` math
\begin{align*}
& \frac{\phi^{\prime}(y-1)}{\phi(y)} \phi(x) \leqslant \phi^{\prime}(x-1) . \\
\left|\delta \beta_{0}\right| \leqslant & \phi^{\prime}(x-1)\left(\frac{\rho \lambda}{\mathrm{e}} \gamma_{1}+(\rho-1) \gamma+K\right) \\
= & \phi^{\prime}(x-1)\left[\gamma(\rho+\mathrm{e} \lambda)+\gamma_{1}(\mathrm{e}+\rho \lambda / \mathrm{e})\right] \\
= & K_{1} \phi^{\prime}(x-1) \quad \text { (say). } \tag{3.6}
\end{align*}
```

The analysis of the sequence $`c_{0}^{\prime}, c_{1}, \ldots`$ is much the same as that in AO and yields, for subtraction (where now $`y-x \geqslant \gamma`$ ), the bound

``` math
\left|\delta c_{l-1}\right| \leqslant\left(1+\frac{a_{l-1}}{c_{l-2}}+\cdots+\frac{a_{l-1} \cdots a_{2}}{c_{l-2} \cdots c_{1}}\right) \gamma_{2}+\frac{a_{l-1} \cdots a_{1}}{c_{l-2} \cdots c_{1} c_{0}^{\prime}}\left|\delta \beta_{0}\right|
```

where, again following AO ,

``` math
\begin{equation*}
\gamma_{2}=\gamma+\lambda \gamma_{1} \ln 1 / \gamma . \tag{3.7}
\end{equation*}
```

Here $`c_{j}=\phi(z-j) / \phi(x-j)>1`$ and so we have, using (3.6),

``` math
\left|\delta c_{l-1}\right| \leqslant \rho \gamma_{2}+\frac{a_{l-1} \cdots a_{1}}{c_{l-2} \cdots c_{1} c_{0}^{\prime}} K_{1} \phi^{\prime}(x-1)=\rho \gamma_{2}+\frac{K_{1}}{c_{l-2} \cdots c_{1} c_{0}^{\prime}}
```

Now $`c_{0}^{\prime}=\phi(x) / \phi(z)`$ and

``` math
c_{1} \cdots c_{l-2}=\frac{\phi(z-1) \cdots \phi(z-l+2)}{\phi(x-1) \cdots \phi(x-l+2)}=\frac{\phi^{\prime}(z-1)}{\phi^{\prime}(x-1)} \frac{\phi(x-l+1)}{\phi^{\prime}(z-l+1)}
```

so that

``` math
\left|\delta h_{l}\right| \leqslant \frac{1}{c_{l-1}}\left|\delta c_{l-1}\right|+\gamma \leqslant \gamma+\rho \gamma_{2}+K_{1} \frac{\phi^{\prime}(x-1) \phi(z)}{\phi^{\prime}(z-1) \phi(x)} \phi^{\prime}(z-l) .
```

Similar arguments to those used above for $`h_{l+1}, h_{l+2}, \ldots`$ finally yield

``` math
\begin{align*}
|\delta z| & \leqslant \rho\left(\gamma+\gamma_{2}\right)+K_{1} \frac{\phi^{\prime}(x-1) \phi(z)}{\phi^{\prime}(z-1) \phi(x)} \\
& \leqslant \frac{\phi^{\prime}(x-1) \phi(z)}{\phi^{\prime}(z-1) \phi(x)}\left[\gamma(3 \rho+\mathrm{e} \lambda)+\gamma_{1}\left(\rho \lambda \ln \frac{1}{\gamma}+\mathrm{e}+\frac{\rho \lambda}{\mathrm{e}}\right)\right] \tag{3.8}
\end{align*}
```

which is the required form.\
In the case of addition, the same analysis yields, for $`j \geqslant 1`$,

``` math
\begin{aligned}
\left|\delta c_{j}\right| & \leqslant\left(1+\frac{a_{j}}{c_{j-1}}+\cdots+\frac{a_{j} \cdots a_{2}}{c_{j-1} \cdots c_{1}}\right) \gamma_{2}+\frac{a_{j} \cdots a_{1}}{c_{j-1} \cdots c_{1} c_{0}^{\prime}}\left|\delta \beta_{0}\right| \\
& \leqslant\left(1+\frac{a_{j}}{c_{j-1}}+\cdots+\frac{a_{j} \cdots a_{2}}{c_{j-1} \cdots c_{1}}\right) \gamma_{2}+K_{1} \frac{\phi^{\prime}(x-1) \phi(z)}{\phi^{\prime}(z-1) \phi(x)} \frac{\phi^{\prime}(z-j)}{\phi(x-j)}
\end{aligned}
```

From this we find that, whenever $`1 / \phi(x)+1 / \phi(y)=1 / \phi(z)`$, then the bound

``` math
\begin{equation*}
|\delta z| \leqslant\left[\gamma(3 \rho+\mathrm{e} \lambda-1)+\gamma_{1}\left(4 \lambda+\mathrm{e}+\frac{\rho \lambda}{\mathrm{e}}+2(\rho-1) \lambda \ln \frac{1}{\gamma}\right)\right] \frac{\phi^{\prime}(x-1) \phi(z)}{\phi^{\prime}(z-1) \phi(x)} . \tag{3.9}
\end{equation*}
```

is satisfied for both $`\lfloor z\rfloor=l`$ and $`\lfloor z\rfloor<l`$.\
For the special case of small addition where the result is greater than unity and we seek $`z`$ such that

``` math
\phi(z)=1 / \phi(x)+1 / \phi(y),
```

we have $`\phi(z), \phi(x) \in[1,2]`$. In this case, we obtain the absolute bound

``` math
|\delta z| \leqslant(2 \lambda+1) \gamma+4 \gamma_{1} .
```

# 4. Working Precisions

The final task of this section is to study the implications of the above analyses for actual working precisions.

In a 32-bit sli representation, two bits are needed for signs and three for the level, leaving 27 bits for the index. From AO we see that, in order to preserve the expected precision in large arithmetic,\
either

``` math
\gamma=2^{-30}, \quad \gamma_{1}=2^{-37}
```

or

``` math
\gamma=2^{-31}, \quad \gamma_{1}=2^{-35}
```

would suffice. With $`\gamma=2^{-31}`$, the corresponding values of $`\gamma_{1}`$ for ’mixed’ and ’small’ arithmetic are $`2^{-34}`$ and $`2^{-36}`$ respectively.

There is no obvious necessity for the same working precisions to be used for all\
operations in a hardware implementation, since these could be executed on different parts of the chip. However, in a software implementation, it may be desirable that, whenever (say) a sequence $`\left\{c_{j}\right\}`$ is required, the precision should be the same. The values $`\gamma=2^{-31}`$ and $`\gamma_{1}=2^{-36}`$ would suffice in all cases.

It is also necessary, of course, to consider the number of bits which may be needed before the binary point: this question is resolved by the bounds given in note ( v ) of Section 2. One such bit will always suffice for each of $`a_{j}, b_{j}, \alpha_{j}`$, and $`\beta_{j}`$, while two will be enough for $`c_{j}`$ except in some cases of small subtraction. The $`h_{j}`$ may also need more. The bounds given for $`c_{1}, h_{l}`$, and $`h_{1}`$ show that, in all cases, it will be sufficient to allow $`c_{j}`$ and $`h_{j}`$ six bits before the point when $`\gamma>2^{-90}`$, while five will suffice if $`\gamma>2^{-44}`$. (In fact only the first computed element of the $`\left\{c_{j}\right\}`$ and $`\left\{h_{j}\right\}`$ sequences can ever need this number of leading bits; the second needs three at most, and the third, two.)

# Acknowledgement

The authors are pleased to acknowledge several helpful discussions with and comments from F. W. J. Olver.

# References

Clenshaw, C. W., & Olver, F. W. J. 1984 Beyond floating point. J. ACM 31, 319-328.\
Clenshaw, C. W., & Olver, F. W. J. 1987 Level-index arithmetic operations. SiaM J. on num. Anal. 24, 470-485.\
Clenshaw, C. W., & Turner, P. R. 1988 Root-squaring using level-index arithmetic. (In preparation).\
Lozier, D. W., & Olver, F. W. J. 1988 Closure and precision in computer arithmetic. (In preparation).\
Turner, P. R. 1986 Towards a fast implementation of level-index arithmetic. Bull. IMA 22, 188-191.
