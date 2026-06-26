packagePath = FileNameJoin[{DirectoryName[DirectoryName[$InputFileName]], "InverseAsymptotic.wl"}];
Get[packagePath];

VerificationTest[
  FullSimplify[
    InverseAsymptotic[
      x + x^2 (1 + Log[x]),
      {x, 0},
      {y, 0},
      SeriesTermGoal -> 2,
      Assumptions -> y > 0
    ] == y - y^2 (1 + Log[y]),
    y > 0
  ],
  True,
  TestID -> "logarithmic-real-branch-term-goal-2"
]

VerificationTest[
  FullSimplify[
    InverseAsymptotic[
      x + x^2 (1 + Log[x]),
      {x, 0},
      {y, 0},
      SeriesTermGoal -> 4,
      Assumptions -> y > 0,
      "PostSimplify" -> None
    ] ==
      y - y^2 + 3 y^3 - 23 y^4/2 -
        y^2 Log[y] + 5 y^3 Log[y] - 27 y^4 Log[y] +
        2 y^3 Log[y]^2 - 41 y^4 Log[y]^2/2 - 5 y^4 Log[y]^3,
    y > 0
  ],
  True,
  TestID -> "logarithmic-real-branch-term-goal-4"
]

VerificationTest[
  FullSimplify[
    InverseAsymptotic[
      ConditionalExpression[# + #^Sqrt[2], # >= 0] &,
      {x, 0},
      {z, 0},
      SeriesTermGoal -> 4,
      Assumptions -> z > 0,
      "PostSimplify" -> None
    ] ==
      z - z^Sqrt[2] + Sqrt[2] z^(2 Sqrt[2] - 1) -
        (6 - Sqrt[2]) z^(3 Sqrt[2] - 2)/2,
    z > 0
  ],
  True,
  TestID -> "conditional-irrational-puiseux-branch"
]

VerificationTest[
  FullSimplify[
    InverseAsymptotic[
      x + x^2,
      {x, 0},
      {y, 0},
      SeriesTermGoal -> 4,
      Assumptions -> y > 0,
      "PostSimplify" -> None
    ] == y - y^2 + 2 y^3 - 5 y^4,
    y > 0
  ],
  True,
  TestID -> "analytic-nontrivial-inverse"
]

VerificationTest[
  FullSimplify[
    InverseAsymptotic[
      2 x + x^2,
      {x, 0},
      {y, 0},
      SeriesTermGoal -> 4,
      Assumptions -> y > 0,
      "PostSimplify" -> None
    ] == y/2 - y^2/8 + y^3/16 - 5 y^4/128,
    y > 0
  ],
  True,
  TestID -> "nonunit-linear-leading-coefficient"
]

VerificationTest[
  FullSimplify[
    InverseAsymptotic[
      x^2 + x^3,
      {x, 0},
      {y, 0},
      SeriesTermGoal -> 4,
      Assumptions -> y > 0,
      "PostSimplify" -> None
    ] == Sqrt[y] - y/2 + 5 y^(3/2)/8 - y^2,
    y > 0
  ],
  True,
  TestID -> "puiseux-leading-term"
]

VerificationTest[
  InverseAsymptoticVerify[
    x + x^2 (1 + Log[x]),
    y - y^2 (1 + Log[y]),
    {x, 0},
    {y, 0},
    SeriesTermGoal -> 2,
    Assumptions -> y > 0
  ]["ResidualSmallerThanLastTerm"],
  True,
  TestID -> "composition-residual-smaller-than-last-retained-term"
]
