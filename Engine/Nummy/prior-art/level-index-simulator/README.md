a# level-index-simulator

# `sli` - A custom precision MATLAB symmetric level-index arithmetic simulator.

## About

`sli` is a MATLAB toolbox that provides sli objects and operations on them.

* [sli.m](sli.m) - the main object file.
* [tests](./tests) - various testing scripts that test the accuracy of representation and operations.
* [experiments](./experiments) - scripts to reproduce the experiments with level-index arithmetic in [1].

[![Open in MATLAB Online](https://www.mathworks.com/images/responsive/global/open-in-matlab-online.svg)](https://matlab.mathworks.com/open/github/v1?repo=north-numerical-computing/level-index-simulator)

## Quick start

```
x = sli(2,12);
x = x.set_val(pi)
x =

  sli with properties:

    level_bits: 2
    index_bits: 12
          sign: 0
    reciprocal: 1
         level: 2
         index: 0.135253906250000
         value: 3.141899100868418
```

### Installation

Clone the repository and add the root directory to the MATLAB search path.

## Requirements

The code was developed on MATLAB 2023b. Experiments make use of the [CPFloat](https://github.com/north-numerical-computing/cpfloat) package.

## References

[1] Mantas Mikaitis. [*MATLAB Simulator of Level-Index Arithmetic*](https://ieeexplore.ieee.org/document/10579434). Proc. 31st IEEE Symp. Comput. Arithmetic. Málaga, Spain. Jul. 2024.

## Licence

The code is distributed under the terms of the BSD 2-Clause License;
see [license.txt](license.txt).
