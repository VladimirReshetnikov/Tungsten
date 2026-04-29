**GNUMP**

The GNU Multiple Precision Arithmetic Library

Edition 6.3.0

29 July 2023

**by Torbjo¨rn Granlund and the GMP development team**

This manual describes how to install and use the GNU multiple precision arithmetic library, version 6.3.0.

Copyright 1991, 1993-2016, 2018-2020 Free Software Foundation, Inc.

Permission is granted to copy, distribute and/or modify this document under the terms of the GNU Free Documentation License, Version 1.3 or any later version published by the Free Software Foundation; with no Invariant Sections, with the Front-Cover Texts being "A GNU Manual", and with the Back-Cover Texts being "You have freedom to copy and modify this GNU Manual, like GNU software". A copy of the license is included in Appendix C \[GNU Free Documentation License\], page 132.

i

**Table of Contents**

**GNU MP Copying Conditions** _..................................._ **1**

- **Introduction to GNU MP** _...................................._ **2**
  - How to use this Manual _..........................................................._ 2
- **Installing GMP** _................................................_ **3**
  - Build Options _....................................................................._ 3
  - ABI and ISA*......................................................................* 8 2.3 Notes for Package Builds _........................................................._ 11 2.4 Notes for Particular Systems _....................................................._ 12

  2.5 Known Build Problems*...........................................................* 14 2.6 Performance optimization _........................................................_ 15

- **GMP Basics** _.................................................._ **17**
  - Headers and Libraries _............................................................_ 17
  - Nomenclature and Types _........................................................._ 17
  - Function Classes _................................................................._ 19 3.4 Variable Conventions*.............................................................* 19
  - Parameter Conventions*...........................................................* 20
  - Memory Management _............................................................_ 21
  - Reentrancy*.......................................................................* 21
  - Useful Macros and Constants*.....................................................* 22
  - Compatibility with older versions*.................................................* 22
  - Demonstration programs _........................................................_ 22
  - Efficiency _......................................................................._ 23
  - Debugging _......................................................................_ 25 3.13 Profiling _........................................................................_ 27

  3.14 Autoconf*........................................................................* 28 3.15 Emacs _.........................................................................._ 29

- **Reporting Bugs**_..............................................._ **30**
- **Integer Functions**_............................................._ **31**
  - Initialization Functions*...........................................................* 31
  - Assignment Functions _............................................................_ 32 5.3 Combined Initialization and Assignment Functions*................................* 32

  5.4 Conversion Functions*.............................................................* 33 5.5 Arithmetic Functions*.............................................................* 34 5.6 Division Functions _..............................................................._ 34

  5.7 Exponentiation Functions _........................................................_ 36 5.8 Root Extraction Functions _......................................................._ 37

- 1. Number Theoretic Functions _....................................................._ 38
  - Comparison Functions*...........................................................* 40
  - Logical and Bit Manipulation Functions _........................................._ 40
  - Input and Output Functions*.....................................................* 41
  - Random Number Functions _....................................................._ 42

ii

- 1. Integer Import and Export _......................................................_ 43
  - Miscellaneous Functions*.........................................................* 44
  - Special Functions _..............................................................._ 45

- **Rational Number Functions** _................................._ **47**
  - Initialization and Assignment Functions _.........................................._ 47
  - Conversion Functions*.............................................................* 48 6.3 Arithmetic Functions*.............................................................* 48
  - Comparison Functions*............................................................* 49
  - Applying Integer Functions to Rationals _.........................................._ 49
  - Input and Output Functions*......................................................* 50
- **Floating-point Functions**_....................................._ **52**
  - Initialization Functions*...........................................................* 52
  - Assignment Functions _............................................................_ 54
  - Combined Initialization and Assignment Functions*................................* 55
  - Conversion Functions*.............................................................* 55 7.5 Arithmetic Functions*.............................................................* 56 7.6 Comparison Functions*............................................................* 57

  7.7 Input and Output Functions*......................................................* 57 7.8 Miscellaneous Functions _.........................................................._ 58

- **Low-level Functions** _.........................................._ **60**
  - Low-level functions for cryptography*..............................................* 67 8.2 Nails*.............................................................................* 70
- **Random Number Functions** _................................._ **72**
  - Random State Initialization _......................................................_ 72
  - Random State Seeding _..........................................................._ 73
  - Random State Miscellaneous _....................................................._ 73
- **Formatted Output** _.........................................._ **74**
  - Format Strings*..................................................................* 74
  - Functions _......................................................................._ 76 10.3 C++ Formatted Output*.........................................................* 77
- **Formatted Input** _............................................_ **79**
  - Formatted Input Strings*.........................................................* 79
  - Formatted Input Functions*......................................................* 81 11.3 C++ Formatted Input _.........................................................._ 81
- **C++ Class Interface**_........................................_ **83**
  - C++ Interface General*..........................................................* 83
  - C++ Interface Integers*..........................................................* 84
  - C++ Interface Rationals _........................................................_ 86 12.4 C++ Interface Floats _..........................................................._ 87

  12.5 C++ Interface Random Numbers*................................................* 89 12.6 C++ Interface Limitations _......................................................_ 90

- **Custom Allocation**_.........................................._ **92**

iii

- **Language Bindings**_.........................................._ **94**
- **Algorithms** _.................................................._ **96**
  - Multiplication*...................................................................* 96
    - Basecase Multiplication*.....................................................* 96
    - Karatsuba Multiplication*...................................................* 97
    - Toom 3-Way Multiplication*.................................................* 98
    - Toom 4-Way Multiplication _..............................................._ 100
    - Higher degree Toom'n'half*.................................................* 100
    - FFT Multiplication*........................................................* 100 15.1.7 Other Multiplication _......................................................_ 102

  15.1.8 Unbalanced Multiplication*.................................................* 102

- 1. Division Algorithms*............................................................* 103 - Single Limb Division _......................................................_ 103 - Basecase Division _........................................................._ 103 - Divide and Conquer Division _.............................................._ 104 - Block-Wise Barrett Division*...............................................* 104 - Exact Division _............................................................_ 104 15.2.6 Exact Remainder*..........................................................* 105 15.2.7 Small Quotient Division _..................................................._ 106
  - Greatest Common Divisor*......................................................* 106
    - Binary GCD _.............................................................._ 106
    - Lehmer's algorithm*........................................................* 107
    - Subquadratic GCD*........................................................* 107 15.3.4 Extended GCD*............................................................* 108

  15.3.5 Jacobi Symbol _............................................................_ 108

- 1. Powering Algorithms*...........................................................* 109 - Normal Powering*..........................................................* 109 - Modular Powering*.........................................................* 109
  - Root Extraction Algorithms*....................................................* 109
    - Square Root _.............................................................._ 110 15.5.2 Nth Root _................................................................._ 110
    - Perfect Square _............................................................_ 111
    - Perfect Power _............................................................._ 111
  - Radix Conversion _.............................................................._ 111
    - Binary to Radix*...........................................................* 111 15.6.2 Radix to Binary*...........................................................* 112
  - Other Algorithms _.............................................................._ 113
    - Prime Testing*.............................................................* 113
    - Factorial _.................................................................._ 113
    - Binomial Coefficients*......................................................* 114
    - Fibonacci Numbers*........................................................* 114 15.7.5 Lucas Numbers*............................................................* 115

  15.7.6 Random Numbers*.........................................................* 115

- 1. Assembly Coding _.............................................................._ 116 - Code Organisation _........................................................_ 116 15.8.2 Assembly Basics*...........................................................* 116

     15.8.3 Carry Propagation _........................................................_ 117 15.8.4 Cache Handling _..........................................................._ 117 15.8.5 Functional Units _.........................................................._ 118

     15.8.6 Floating Point*.............................................................* 118 15.8.7 SIMD Instructions _........................................................_ 119

- - 1. Software Pipelining*........................................................* 119

iv

- - 1. Loop Unrolling*............................................................* 120 15.8.10 Writing Guide _..........................................................._ 120

- **Internals**_...................................................._ **122**
  - Integer Internals _..............................................................._ 122 16.2 Rational Internals*..............................................................* 122 16.3 Float Internals*.................................................................* 123

  16.4 Raw Output Internals*..........................................................* 125 16.5 C++ Interface Internals*........................................................* 125

**Appendix A Contributors**_...................................._ **128**

**Appendix B References** _......................................_ **130**

- 1. Books _.........................................................................._ 130
  - Papers*..........................................................................* 130

**Appendix C GNU Free Documentation License** _..........._ **132**

**Concept Index** _.................................................._ **139**

**Function and Type Index** _......................................_ **143**

GNU MP Copying Conditions

# GNU MP Copying Conditions

This library is _free_; this means that everyone is free to use it and free to redistribute it on a free basis. The library is not in the public domain; it is copyrighted and there are restrictions on its distribution, but these restrictions are designed to permit everything that a good cooperating citizen would want to do. What is not allowed is to try to prevent others from further sharing any version of this library that they might get from you.

Specifically, we want to make sure that you have the right to give away copies of the library, that you receive source code or else can get it if you want it, that you can change this library or use pieces of it in new free programs, and that you know you can do these things.

To make sure that everyone has such rights, we have to forbid you to deprive anyone else of these rights. For example, if you distribute copies of the GNU MP library, you must give the recipients all the rights that you have. You must make sure that they, too, receive or can get the source code. And you must tell them their rights.

Also, for our own protection, we must make certain that everyone finds out that there is no warranty for the GNU MP library. If it is modified by someone else and passed on, we want their recipients to know that what they have is not what we distributed, so that any problems introduced by others will not reflect on our reputation.

More precisely, the GNU MP library is dual licensed, under the conditions of the GNU Lesser General Public License version 3 (see COPYING.LESSERv3), or the GNU General Public License version 2 (see COPYINGv2). This is the recipient's choice, and the recipient also has the additional option of applying later versions of these licenses. (The reason for this dual licensing is to make it possible to use the library with programs which are licensed under GPL version 2, but which for historical or other reasons do not allow use under later versions of the GPL.)

Programs which are not part of the library itself, such as demonstration programs and the GMP testsuite, are licensed under the terms of the GNU General Public License version 3 (see COPYINGv3), or any later version.

# 1 Introduction to GNU MP

GNU MP is a portable library written in C for arbitrary precision arithmetic on integers, rational numbers, and floating-point numbers. It aims to provide the fastest possible arithmetic for all applications that need higher precision than is directly supported by the basic C types.

Many applications use just a few hundred bits of precision; but some applications may need thousands or even millions of bits. GMP is designed to give good performance for both, by choosing algorithms based on the sizes of the operands, and by carefully keeping the overhead at a minimum.

The speed of GMP is achieved by using fullwords as the basic arithmetic type, by using sophisticated algorithms, by including carefully optimized assembly code for the most common inner loops for many different CPUs, and by a general emphasis on speed (as opposed to simplicity or elegance).

There is assembly code for these CPUs: ARM Cortex-A9, Cortex-A15, and generic ARM, DEC Alpha 21064, 21164, and 21264, AMD K8 and K10 (sold under many brands, e.g. Athlon64, Phenom, Opteron), Bulldozer, and Bobcat, Intel Pentium, Pentium Pro/II/III, Pentium 4, Core2, Nehalem, Sandy bridge, Haswell, generic x86, Intel IA-64, Motorola/IBM PowerPC 32 and 64 such as POWER970, POWER5, POWER6, and POWER7, MIPS 32-bit and 64bit, SPARC 32-bit and 64-bit with special support for all UltraSPARC models. There is also assembly code for many obsolete CPUs.

For up-to-date information on GMP, please see the GMP web pages at <https://gmplib.org/>

The latest version of the library is available at <https://ftp.gnu.org/gnu/gmp/>

Many sites around the world mirror 'ftp.gnu.org', please use a mirror near you, see [https:// www.gnu.org/order/ftp.html](https://www.gnu.org/order/ftp.html) for a full list.

There are three public mailing lists of interest. One for release announcements, one for general questions and discussions about usage of the GMP library and one for bug reports. For more information, see <https://gmplib.org/mailman/listinfo/>.

The proper place for bug reports is <gmp-bugs@gmplib.org>. See Chapter 4 \[Reporting Bugs\], page 30 for information about reporting bugs.

## 1.1 How to use this Manual

Everyone should read Chapter 3 \[GMP Basics\], page 17. If you need to install the library yourself, then read Chapter 2 \[Installing GMP\], page 3. If you have a system with multiple ABIs, then read Section 2.2 \[ABI and ISA\], page 8, for the compiler options that must be used on applications.

The rest of the manual can be used for later reference, although it is probably a good idea to glance through it.

# 2 Installing GMP

GMP has an autoconf/automake/libtool based configuration system. On a Unix-like system a basic build can be done with

./configure make

Some self-tests can be run with make check

And you can install (under /usr/local by default) with make install

If you experience problems, please report them to <gmp-bugs@gmplib.org>. See Chapter 4 \[Reporting Bugs\], page 30, for information on what to include in useful bug reports.

## 2.1 Build Options

All the usual autoconf configure options are available, run './configure--help' for a summary. The file INSTALL.autoconf has some generic installation information too.

Tools 'configure' requires various Unix-like tools. See Section 2.4 \[Notes for Particular Systems\], page 12, for some options on non-Unix systems.

It might be possible to build without the help of 'configure', certainly all the code is there, but unfortunately you'll be on your own.

Build Directory

To compile in a separate build directory, cd to that directory, and prefix the configure command with the path to the GMP source directory. For example cd /my/build/dir

/my/sources/gmp-6.3.0/configure

Not all 'make' programs have the necessary features (VPATH) to support this. In particular, SunOS and Slowaris make have bugs that make them unable to build in a separate directory. Use GNU make instead.

\--prefix and --exec-prefix

The --prefix option can be used in the normal way to direct GMP to install under a particular tree. The default is '/usr/local'.

\--exec-prefix can be used to direct architecture-dependent files like libgmp.a to a different location. This can be used to share architecture-independent parts like the documentation, but separate the dependent parts. Note however that gmp.h is architecture-dependent since it encodes certain aspects of libgmp, so it will be necessary to ensure both \$prefix/include and \$exec_prefix/include are available to the compiler.

\--disable-shared, --disable-static

By default both shared and static libraries are built (where possible), but one or other can be disabled. Shared libraries result in smaller executables and permit code sharing between separate running processes, but on some CPUs are slightly slower, having a small cost on each function call.

Native Compilation, --build=CPU-VENDOR-OS

For normal native compilation, the system can be specified with '--build'. By default './configure' uses the output from running './config.guess'. On some systems './config.guess' can determine the exact CPU type, on others it will be necessary to give it explicitly. For example,

./configure --build=ultrasparc-sun-solaris2.7

In all cases the 'OS' part is important, since it controls how libtool generates shared libraries. Running './config.guess' is the simplest way to see what it should be, if you don't know already.

Cross Compilation, --host=CPU-VENDOR-OS

When cross-compiling, the system used for compiling is given by '--build' and the system where the library will run is given by '--host'. For example when using a

FreeBSD Athlon system to build GNU/Linux m68k binaries,

./configure --build=athlon-pc-freebsd3.5 --host=m68k-mac-linux-gnu

Compiler tools are sought first with the host system type as a prefix. For example m68k-mac-linux-gnu-ranlib is tried, then plain ranlib. This makes it possible for a set of cross-compiling tools to co-exist with native tools. The prefix is the argument to '--host', and this can be an alias, such as 'm68k-linux'. But note that tools don't have to be set up this way, it's enough to just have a PATH with a suitable cross-compiling cc etc.

Compiling for a different CPU in the same family as the build system is a form of cross-compilation, though very possibly this would merely be special options on a native compiler. In any case './configure' avoids depending on being able to run code on the build system, which is important when creating binaries for a newer CPU since they very possibly won't run on the build system.

In all cases the compiler must be able to produce an executable (of whatever format) from a standard C main. Although only object files will go to make up libgmp, './configure' uses linking tests for various purposes, such as determining what functions are available on the host system.

Currently a warning is given unless an explicit '--build' is used when crosscompiling, because it may not be possible to correctly guess the build system type if the PATH has only a cross-compiling cc.

Note that the '--target' option is not appropriate for GMP. It's for use when building compiler tools, with '--host' being where they will run, and '--target' what they'll produce code for. Ordinary programs or libraries like GMP are only interested in the '--host' part, being where they'll run. (Some past versions of GMP used '--target' incorrectly.)

CPU types

In general, if you want a library that runs as fast as possible, you should configure GMP for the exact CPU type your system uses. However, this may mean the binaries won't run on older members of the family, and might run slower on other members, older or newer. The best idea is always to build GMP for the exact machine type you intend to run it on.

The following CPUs have specific support. See configure.ac for details of what code and compiler options they select.

- Alpha: 'alpha', 'alphaev5', 'alphaev56', 'alphapca56', 'alphapca57',

'alphaev6', 'alphaev67', 'alphaev68', 'alphaev7'

- Cray: 'c90', 'j90', 't90', 'sv1'
- HPPA: 'hppa1.0', 'hppa1.1', 'hppa2.0', 'hppa2.0n', 'hppa2.0w', 'hppa64'
- IA-64: 'ia64', 'itanium', 'itanium2'
- MIPS: 'mips', 'mips3', 'mips64'
- Motorola: 'm68k', 'm68000', 'm68010', 'm68020', 'm68030', 'm68040', 'm68060', 'm68302', 'm68360', 'm88k', 'm88110'
- POWER: 'power', 'power1', 'power2', 'power2sc'
- PowerPC: 'powerpc', 'powerpc64', 'powerpc401', 'powerpc403', 'powerpc405', 'powerpc505', 'powerpc601', 'powerpc602', 'powerpc603', 'powerpc603e',

'powerpc604', 'powerpc604e', 'powerpc620', 'powerpc630', 'powerpc740', 'powerpc7400', 'powerpc7450', 'powerpc750', 'powerpc801', 'powerpc821', 'powerpc823', 'powerpc860', 'powerpc970'

- SPARC: 'sparc', 'sparcv8', 'microsparc', 'supersparc', 'sparcv9', 'ultrasparc', 'ultrasparc2', 'ultrasparc2i', 'ultrasparc3', 'sparc64'
- x86 family: 'i386', 'i486', 'i586', 'pentium', 'pentiummmx', 'pentiumpro',

'pentium2', 'pentium3', 'pentium4', 'k6', 'k62', 'k63', 'athlon', 'amd64', 'viac3', 'viac32'

- Other: 'arm', 'sh', 'sh2', 'vax',

CPUs not listed will use generic C code.

Generic C Build

If some of the assembly code causes problems, or if otherwise desired, the generic C code can be selected with the configure --disable-assembly.

Note that this will run quite slowly, but it should be portable and should at least make it possible to get something running if all else fails.

Fat binary, --enable-fat

Using --enable-fat selects a "fat binary" build on x86, where optimized low level subroutines are chosen at runtime according to the CPU detected. This means more code, but gives good performance on all x86 chips. (This option might become available for more architectures in the future.)

ABI On some systems GMP supports multiple ABIs (application binary interfaces),

meaning data type sizes and calling conventions. By default GMP chooses the best ABI available, but a particular ABI can be selected. For example

./configure --host=mips64-sgi-irix6 ABI=n32

See Section 2.2 \[ABI and ISA\], page 8, for the available choices on relevant CPUs, and what applications need to do.

CC, CFLAGS

By default the C compiler used is chosen from among some likely candidates, with gcc normally preferred if it's present. The usual 'CC=whatever' can be passed to './configure' to choose something different.

For various systems, default compiler flags are set based on the CPU and compiler. The usual 'CFLAGS="-whatever"' can be passed to './configure' to use something different or to set good flags for systems GMP doesn't otherwise know.

The 'CC' and 'CFLAGS' used are printed during './configure', and can be found in each generated Makefile. This is the easiest way to check the defaults when considering changing or adding something.

Note that when 'CC' and 'CFLAGS' are specified on a system supporting multiple ABIs it's important to give an explicit 'ABI=whatever', since GMP can't determine the ABI just from the flags and won't be able to select the correct assembly code.

If just 'CC' is selected then normal default 'CFLAGS' for that compiler will be used (if GMP recognises it). For example 'CC=gcc' can be used to force the use of GCC, with default flags (and default ABI).

CPPFLAGS Any flags like '-D' defines or '-I' includes required by the preprocessor should be set in 'CPPFLAGS' rather than 'CFLAGS'. Compiling is done with both 'CPPFLAGS' and 'CFLAGS', but preprocessing uses just 'CPPFLAGS'. This distinction is because most preprocessors won't accept all the flags the compiler does. Preprocessing is done separately in some configure tests.

CC_FOR_BUILD

Some build-time programs are compiled and run to generate host-specific data tables. 'CC_FOR_BUILD' is the compiler used for this. It doesn't need to be in any particular ABI or mode, it merely needs to generate executables that can run. The default is to try the selected 'CC' and some likely candidates such as 'cc' and 'gcc', looking for something that works.

No flags are used with 'CC_FOR_BUILD' because a simple invocation like 'ccfoo.c' should be enough. If some particular options are required they can be included as for instance 'CC_FOR_BUILD="cc-whatever"'.

C++ Support, --enable-cxx

C++ support in GMP can be enabled with '--enable-cxx', in which case a C++ compiler will be required. As a convenience '--enable-cxx=detect' can be used to enable C++ support only if a compiler can be found. The C++ support consists of a library libgmpxx.la and header file gmpxx.h (see Section 3.1 \[Headers and Libraries\], page 17).

A separate libgmpxx.la has been adopted rather than having C++ objects within libgmp.la in order to ensure dynamic linked C programs aren't bloated by a dependency on the C++ standard library, and to avoid any chance that the C++ compiler could be required when linking plain C programs.

libgmpxx.la will use certain internals from libgmp.la and can only be expected to work with libgmp.la from the same GMP version. Future changes to the relevant internals will be accompanied by renaming, so a mismatch will cause unresolved symbols rather than perhaps mysterious misbehaviour.

In general libgmpxx.la will be usable only with the C++ compiler that built it, since name mangling and runtime support are usually incompatible between different compilers.

CXX, CXXFLAGS

When C++ support is enabled, the C++ compiler and its flags can be set with variables 'CXX' and 'CXXFLAGS' in the usual way. The default for 'CXX' is the first compiler that works from a list of likely candidates, with g++ normally preferred when available. The default for 'CXXFLAGS' is to try 'CFLAGS', 'CFLAGS' without '-g', then for g++ either '-g-O2' or '-O2', or for other compilers '-g' or nothing. Trying 'CFLAGS' this way is convenient when using 'gcc' and 'g++' together, since the flags for 'gcc' will usually suit 'g++'.

It's important that the C and C++ compilers match, meaning their startup and runtime support routines are compatible and that they generate code in the same ABI (if there's a choice of ABIs on the system). './configure' isn't currently able to check these things very well itself, so for that reason '--disable-cxx' is the default, to avoid a build failure due to a compiler mismatch. Perhaps this will change in the future.

Incidentally, it's normally not good enough to set 'CXX' to the same as 'CC'. Although gcc for instance recognises foo.cc as C++ code, only g++ will invoke the linker the right way when building an executable or shared library from C++ object files.

Temporary Memory, --enable-alloca=&lt;choice&gt;

GMP allocates temporary workspace using one of the following three methods, which can be selected with for instance '--enable-alloca=malloc-reentrant'.

- 'alloca' - C library or compiler builtin.
- 'malloc-reentrant' - the heap, in a re-entrant fashion.
- 'malloc-notreentrant' - the heap, with global variables.

For convenience, the following choices are also available. '--disable-alloca' is the same as 'no'.

- 'yes' - a synonym for 'alloca'.
- 'no' - a synonym for 'malloc-reentrant'.
- 'reentrant' - alloca if available, otherwise 'malloc-reentrant'. This is the default.
- 'notreentrant' - alloca if available, otherwise 'malloc-notreentrant'.

alloca is reentrant and fast, and is recommended. It actually allocates just small blocks on the stack; larger ones use malloc-reentrant.

'malloc-reentrant' is, as the name suggests, reentrant and thread safe, but 'malloc-notreentrant' is faster and should be used if reentrancy is not required.

The two malloc methods in fact use the memory allocation functions selected by mp_set_memory_functions, these being malloc and friends by default. See Chapter 13 \[Custom Allocation\], page 92.

An additional choice '--enable-alloca=debug' is available, to help when debugging memory related problems (see Section 3.12 \[Debugging\], page 25).

FFT Multiplication, --disable-fft

By default multiplications are done using Karatsuba, 3-way Toom, higher degree Toom, and Fermat FFT. The FFT is only used on large to very large operands and can be disabled to save code size if desired.

Assertion Checking, --enable-assert

This option enables some consistency checking within the library. This can be of use while debugging, see Section 3.12 \[Debugging\], page 25.

Execution Profiling, --enable-profiling=prof/gprof/instrument

Enable profiling support, in one of various styles, see Section 3.13 \[Profiling\], page 27.

MPN_PATH Various assembly versions of each mpn subroutines are provided. For a given CPU, a search is made through a path to choose a version of each. For example 'sparcv8' has

MPN_PATH="sparc32/v8 sparc32 generic" which means look first for v8 code, then plain sparc32 (which is v7), and finally fall back on generic C. Knowledgeable users with special requirements can specify a different path. Normally this is completely unnecessary.

Documentation

The source for the document you're now reading is doc/gmp.texi, in Texinfo format, see _Texinfo_.

Info format 'doc/gmp.info' is included in the distribution. The usual automake targets are available to make PostScript, DVI, PDF and HTML (these will require various TEX and Texinfo tools).

DocBook and XML can be generated by the Texinfo makeinfo program too, see Section "Options for makeinfo" in _Texinfo_.

Some supplementary notes can also be found in the doc subdirectory.

## 2.2 ABI and ISA

ABI (Application Binary Interface) refers to the calling conventions between functions, meaning what registers are used and what sizes the various C data types are. ISA (Instruction Set Architecture) refers to the instructions and registers a CPU has available.

Some 64-bit ISA CPUs have both a 64-bit ABI and a 32-bit ABI defined, the latter for compatibility with older CPUs in the family. GMP supports some CPUs like this in both ABIs. In fact within GMP 'ABI' means a combination of chip ABI, plus how GMP chooses to use it. For example in some 32-bit ABIs, GMP may support a limb as either a 32-bit long or a 64-bit long long.

By default GMP chooses the best ABI available for a given system, and this generally gives significantly greater speed. But an ABI can be chosen explicitly to make GMP compatible with other libraries, or particular application requirements. For example,

./configure ABI=32

In all cases it's vital that all object code used in a given program is compiled for the same ABI.

Usually a limb is implemented as a long. When a longlong limb is used this is encoded in the generated gmp.h. This is convenient for applications, but it does mean that gmp.h will vary, and can't be just copied around. gmp.h remains compiler independent though, since all compilers for a particular ABI will be expected to use the same limb type.

Currently no attempt is made to follow whatever conventions a system has for installing library or header files built for a particular ABI. This will probably only matter when installing multiple builds of GMP, and it might be as simple as configuring with a special 'libdir', or it might require more than that. Note that builds for different ABIs need to be done separately, with a fresh ./configure and make each.

AMD64 ('x86_64')

On AMD64 systems supporting both 32-bit and 64-bit modes for applications, the following ABI choices are available.

| 'ABI=64'  | The 64-bit ABI uses 64-bit limbs and pointers and makes full use of the chip architecture. This is the default. Applications will usually not need special compiler flags, but for reference the option is<br><br>gcc -m64                                                                     |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 'ABI=32'  | The 32-bit ABI is the usual i386 conventions. This will be slower, and is not recommended except for inter-operating with other code not yet 64-bit capable. Applications must be compiled with<br><br>gcc -m32<br><br>(In GCC 2.95 and earlier there's no '-m32' option, it's the only mode.) |
| 'ABI=x32' | The x32 ABI uses 64-bit limbs but 32-bit pointers. Like the 64-bit ABI, it makes full use of the chip's arithmetic capabilities. This ABI is not supported by all operating systems.                                                                                                           |

gcc -mx32

HPPA 2.0 ('hppa2.0\*', 'hppa64')

'ABI=2.0w'

The 2.0w ABI uses 64-bit limbs and pointers and is available on HP-UX

11 or up. Applications must be compiled with gcc \[built for 2.0w\] cc +DD64

'ABI=2.0n'

The 2.0n ABI means the 32-bit HPPA 1.0 ABI and all its normal calling conventions, but with 64-bit instructions permitted within functions. GMP uses a 64-bit longlong for a limb. This ABI is available on hppa64 GNU/Linux and on HP-UX 10 or higher. Applications must be compiled with

gcc \[built for 2.0n\] cc +DA2.0 +e

Note that current versions of GCC (e.g. 3.2) don't generate 64-bit instructions for longlong operations and so may be slower than for 2.0w. (The GMP assembly code is the same though.)

'ABI=1.0' HPPA 2.0 CPUs can run all HPPA 1.0 and 1.1 code in the 32-bit HPPA 1.0 ABI. No special compiler options are needed for applications.

All three ABIs are available for CPU types 'hppa2.0w', 'hppa2.0' and 'hppa64', but for CPU type 'hppa2.0n' only 2.0n or 1.0 are considered.

Note that GCC on HP-UX has no options to choose between 2.0n and 2.0w modes, unlike HP cc. Instead it must be built for one or the other ABI. GMP will detect how it was built, and skip to the corresponding 'ABI'.

IA-64 under HP-UX ('ia64\*-\*-hpux\*', 'itanium\*-\*-hpux\*')

HP-UX supports two ABIs for IA-64. GMP performance is the same in both.

'ABI=32' In the 32-bit ABI, pointers, ints and longs are 32 bits and GMP uses a 64 bit longlong for a limb. Applications can be compiled without any special flags since this ABI is the default in both HP C and GCC, but for reference the flags are

gcc -milp32 cc +DD32

'ABI=64' In the 64-bit ABI, longs and pointers are 64 bits and GMP uses a long for a limb. Applications must be compiled with

gcc -mlp64 cc +DD64

On other IA-64 systems, GNU/Linux for instance, 'ABI=64' is the only choice.

MIPS under IRIX 6 ('mips\*-\*-irix\[6789\]')

IRIX 6 always has a 64-bit MIPS 3 or better CPU, and supports ABIs o32, n32, and 64. n32 or 64 are recommended, and GMP performance will be the same in each. The default is n32.

'ABI=o32' The o32 ABI is 32-bit pointers and integers, and no 64-bit operations. GMP will be slower than in n32 or 64, this option only exists to support old compilers, e.g. GCC 2.7.2. Applications can be compiled with no special flags on an old compiler, or on a newer compiler with

gcc -mabi=32 cc -32

'ABI=n32' The n32 ABI is 32-bit pointers and integers, but with a 64-bit limb using a longlong. Applications must be compiled with gcc -mabi=n32 cc -n32

'ABI=64' The 64-bit ABI is 64-bit pointers and integers. Applications must be compiled with gcc -mabi=64 cc -64

Note that MIPS GNU/Linux, as of kernel version 2.2, doesn't have the necessary support for n32 or 64 and so only gets a 32-bit limb and the MIPS 2 code.

PowerPC 64 ('powerpc64', 'powerpc620', 'powerpc630', 'powerpc970', 'power4', 'power5')

'ABI=mode64'

The AIX 64 ABI uses 64-bit limbs and pointers and is the default on

PowerPC 64 '\*-\*-aix\*' systems. Applications must be compiled with gcc -maix64 xlc -q64

On 64-bit GNU/Linux, BSD, and Mac OS X/Darwin systems, the applications must be compiled with gcc -m64

'ABI=mode32'

The 'mode32' ABI uses a 64-bit longlong limb but with the chip still in 32-bit mode and using 32-bit calling conventions. This is the default for systems where the true 64-bit ABI is unavailable. No special compiler options are typically needed for applications. This ABI is not available under AIX.

'ABI=32' This is the basic 32-bit PowerPC ABI, with a 32-bit limb. No special compiler options are needed for applications.

GMP's speed is greatest for the 'mode64' ABI, the 'mode32' ABI is 2nd best. In 'ABI=32' only the 32-bit ISA is used and this doesn't make full use of a 64-bit chip.

Sparc V9 ('sparc64', 'sparcv9', 'ultrasparc\*')

| 'ABI=64' | The 64-bit V9 ABI is available on the various BSD sparc64 ports, recent versions of Sparc64 GNU/Linux, and Solaris 2.7 and up (when the kernel is in 64-bit mode). GCC 3.2 or higher, or Sun cc is required. On GNU/Linux, depending on the default gcc mode, applications must be compiled with<br><br>gcc -m64<br><br>On Solaris applications must be compiled with gcc -m64 -mptr64 -Wa,-xarch=v9 -mcpu=v9 cc -xarch=v9<br><br>On the BSD sparc64 systems no special options are required, since 64bits is the only ABI available. |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 'ABI=32' | For the basic 32-bit ABI, GMP still uses as much of the V9 ISA as it can. In the Sun documentation this combination is known as "v8plus".                                                                                                                                                                                                                                                                                                                                                                                             |

On GNU/Linux, depending on the default gcc mode, applications may need to be compiled with gcc -m32

On Solaris, no special compiler options are required for applications, though using something like the following is recommended. (gcc 2.8 and earlier only support '-mv8' though.) gcc -mv8plus cc -xarch=v8plus

GMP speed is greatest in 'ABI=64', so it's the default where available. The speed is partly because there are extra registers available and partly because 64-bits is considered the more important case and has therefore had better code written for it.

Don't be confused by the names of the '-m' and '-x' compiler options, they're called 'arch' but effectively control both ABI and ISA.

On Solaris 2.6 and earlier, only 'ABI=32' is available since the kernel doesn't save all registers.

On Solaris 2.7 with the kernel in 32-bit mode, a normal native build will reject 'ABI=64' because the resulting executables won't run. 'ABI=64' can still be built if desired by making it look like a cross-compile, for example

./configure --build=none --host=sparcv9-sun-solaris2.7 ABI=64

## 2.3 Notes for Package Builds

GMP should present no great difficulties for packaging in a binary distribution.

Libtool is used to build the library and '-version-info' is set appropriately, having started from '3:0:0' in GMP 3.0 (see Section "Library interface versions" in _GNU Libtool_).

The GMP 4 series will be upwardly binary compatible in each release and will be upwardly binary compatible with all of the GMP 3 series. Additional function interfaces may be added in each release, so on systems where libtool versioning is not fully checked by the loader an auxiliary mechanism may be needed to express that a dynamic linked application depends on a new enough GMP.

An auxiliary mechanism may also be needed to express that libgmpxx.la (from --enable-cxx, see Section 2.1 \[Build Options\], page 3) requires libgmp.la from the same GMP version, since this is not done by the libtool versioning, nor otherwise. A mismatch will result in unresolved symbols from the linker, or perhaps the loader.

When building a package for a CPU family, care should be taken to use '--host' (or '--build') to choose the least common denominator among the CPUs which might use the package. For example this might mean plain 'sparc' (meaning V7) for SPARCs.

For x86s, --enable-fat sets things up for a fat binary build, making a runtime selection of optimized low level routines. This is a good choice for packaging to run on a range of x86 chips.

Users who care about speed will want GMP built for their exact CPU type, to make best use of the available optimizations. Providing a way to suitably rebuild a package may be useful. This could be as simple as making it possible for a user to omit '--build' (and '--host') so './config.guess' will detect the CPU. But a way to manually specify a '--build' will be wanted for systems where './config.guess' is inexact.

On systems with multiple ABIs, a packaged build will need to decide which among the choices is to be provided, see Section 2.2 \[ABI and ISA\], page 8. A given run of './configure' etc will only build one ABI. If a second ABI is also required then a second run of './configure' etc must be made, starting from a clean directory tree ('makedistclean').

As noted under "ABI and ISA", currently no attempt is made to follow system conventions for install locations that vary with ABI, such as /usr/lib/sparcv9 for 'ABI=64' as opposed to /usr/lib for 'ABI=32'. A package build can override 'libdir' and other standard variables as necessary.

Note that gmp.h is a generated file, and will be architecture and ABI dependent. When attempting to install two ABIs simultaneously it will be important that an application compile gets the correct gmp.h for its desired ABI. If compiler include paths don't vary with ABI options then it might be necessary to create a /usr/include/gmp.h which tests preprocessor symbols and chooses the correct actual gmp.h.

## 2.4 Notes for Particular Systems

AIX 3 and 4

On systems '\*-\*-aix\[34\]\*' shared libraries are disabled by default, since some versions of the native ar fail on the convenience libraries used. A shared build can be attempted with

./configure --enable-shared --disable-static

Note that the '--disable-static' is necessary because in a shared build libtool makes libgmp.a a symlink to libgmp.so, apparently for the benefit of old versions of ld which only recognise .a, but unfortunately this is done even if a fully functional ld is available.

ARM On systems 'arm\*-\*-\*', versions of GCC up to and including 2.95.3 have a bug in unsigned division, giving wrong results for some operands. GMP './configure' will demand GCC 2.95.4 or later.

Compaq C++

Compaq C++ on OSF 5.1 has two flavours of iostream, a standard one and an old pre-standard one (see 'maniostream_intro'). GMP can only use the standard one, which unfortunately is not the default but must be selected by defining \__USE_STD_

IOSTREAM. Configure with for instance

./configure --enable-cxx CPPFLAGS=-D\_\_USE_STD_IOSTREAM

Floating Point Mode

On some systems, the hardware floating point has a control mode which can set all operations to be done in a particular precision, for instance single, double or extended on x86 systems (x87 floating point). The GMP functions involving a double cannot be expected to operate to their full precision when the hardware is in single precision mode. Of course this affects all code, including application code, not just GMP.

FreeBSD 7.x, 8.x, 9.0, 9.1, 9.2 m4 in these releases of FreeBSD has an eval function which ignores its 2nd and 3rd arguments, which makes it unsuitable for .asm file processing. './configure' will detect the problem and either abort or choose another m4 in the PATH. The bug is fixed in FreeBSD 9.3 and 10.0, so either upgrade or use GNU m4. Note that the FreeBSD package system installs GNU m4 under the name 'gm4', which GMP cannot guess.

FreeBSD 7.x, 8.x, 9.x

GMP releases starting with 6.0 do not support 'ABI=32' on FreeBSD/amd64 prior to release 10.0 of the system. The cause is a broken limits.h, which GMP no longer works around.

MS-DOS and MS Windows

On an MS-DOS system DJGPP can be used to build GMP, and on an MS Windows system Cygwin, DJGPP and MINGW can be used. All three are excellent ports of GCC and the various GNU tools. <https://www.cygwin.com/> <http://www.delorie.com/djgpp/> <http://www.mingw.org/>

Microsoft also publishes an Interix "Services for Unix" which can be used to build GMP on Windows (with a normal './configure'), but it's not free software.

MS Windows DLLs

On systems '\*-\*-cygwin\*', '\*-\*-mingw\*' and '\*-\*-pw32\*' by default GMP builds only a static library, but a DLL can be built instead using

./configure --disable-static --enable-shared

Static and DLL libraries can't both be built, since certain export directives in gmp.h must be different.

A MINGW DLL build of GMP can be used with Microsoft C. Libtool doesn't install a .lib format import library, but it can be created with MS lib as follows, and copied to the install directory. Similarly for libmp and libgmpxx. cd .libs

lib /def:libgmp-3.dll.def /out:libgmp-3.lib

MINGW uses the C runtime library 'msvcrt.dll' for I/O, so applications wanting to use the GMP I/O routines must be compiled with 'cl/MD' to do the same. If one of the other C runtime library choices provided by MS C is desired then the suggestion is to use the GMP string functions and confine I/O to the application.

Motorola 68k CPU Types

'm68k' is taken to mean 68000. 'm68020' or higher will give a performance boost on applicable CPUs. 'm68360' can be used for CPU32 series chips. 'm68302' can be used for "Dragonball" series chips, though this is merely a synonym for 'm68000'.

NetBSD 5.x m4 in these releases of NetBSD has an eval function which ignores its 2nd and 3rd arguments, which makes it unsuitable for .asm file processing. './configure' will detect the problem and either abort or choose another m4 in the PATH. The bug is fixed in NetBSD 6, so either upgrade or use GNU m4. Note that the NetBSD package system installs GNU m4 under the name 'gm4', which GMP cannot guess.

OpenBSD 2.6 m4 in this release of OpenBSD has a bug in eval that makes it unsuitable for .asm file processing. './configure' will detect the problem and either abort or choose another m4 in the PATH. The bug is fixed in OpenBSD 2.7, so either upgrade or use GNU m4.

Power CPU Types

In GMP, CPU types 'power\*' and 'powerpc\*' will each use instructions not available on the other, so it's important to choose the right one for the CPU that will be used. Currently GMP has no assembly code support for using just the common instruction subset. To get executables that run on both, the current suggestion is to use the generic C code (--disable-assembly), possibly with appropriate compiler options (like '-mcpu=common' for gcc). CPU 'rs6000' (which is not a CPU but a family of workstations) is accepted by config.sub, but is currently equivalent to --disableassembly.

Sparc CPU Types

'sparcv8' or 'supersparc' on relevant systems will give a significant performance increase over the V7 code selected by plain 'sparc'.

Sparc App Regs

The GMP assembly code for both 32-bit and 64-bit Sparc clobbers the "application registers" g2, g3 and g4, the same way that the GCC default '-mapp-regs' does (see Section "SPARC Options" in _Using the GNU Compiler Collection (GCC)_).

This makes that code unsuitable for use with the special V9 '-mcmodel=embmedany' (which uses g4 as a data segment pointer), and for applications wanting to use those registers for special purposes. In these cases the only suggestion currently is to build GMP with --disable-assembly to avoid the assembly code.

SunOS 4 /usr/bin/m4 lacks various features needed to process .asm files, and instead './configure' will automatically use /usr/5bin/m4, which we believe is always available (if not then use GNU m4).

x86 CPU Types

'i586', 'pentium' or 'pentiummmx' code is good for its intended P5 Pentium chips, but quite slow when run on Intel P6 class chips (PPro, P-II, P-III). 'i386' is a better choice when making binaries that must run on both.

x86 MMX and SSE2 Code

If the CPU selected has MMX code but the assembler doesn't support it, a warning is given and non-MMX code is used instead. This will be an inferior build, since the MMX code that's present is there because it's faster than the corresponding plain integer code. The same applies to SSE2.

Old versions of 'gas' don't support MMX instructions, in particular version 1.92.3 that comes with FreeBSD 2.2.8 or the more recent OpenBSD 3.1 doesn't.

Solaris 2.6 and 2.7 as generate incorrect object code for register to register movq instructions, and so can't be used for MMX code. Install a recent gas if MMX code is wanted on these systems.

## 2.5 Known Build Problems

You might find more up-to-date information at <https://gmplib.org/>.

Compiler link options

The version of libtool currently in use rather aggressively strips compiler options when linking a shared library. This will hopefully be relaxed in the future, but for now if this is a problem the suggestion is to create a little script to hide them, and for instance configure with

./configure CC=gcc-with-my-options

DJGPP ('\*-\*-msdosdjgpp\*')

The DJGPP port of bash 2.03 is unable to run the 'configure' script, it exits silently, having died writing a preamble to config.log. Use bash 2.04 or higher.

'makeall' was found to run out of memory during the final libgmp.la link on one system tested, despite having 64MiB available. Running 'makelibgmp.la' directly helped, perhaps recursing into the various subdirectories uses up memory.

GNU binutils strip prior to 2.12 strip from GNU binutils 2.11 and earlier should not be used on the static libraries libgmp.a and libmp.a since it will discard all but the last of multiple archive members with the same name, like the three versions of init.o in libgmp.a. Binutils 2.12 or higher can be used successfully.

The shared libraries libgmp.so and libmp.so are not affected by this and any version of strip can be used on them.

make syntax error

On certain versions of SCO OpenServer 5 and IRIX 6.5 the native make is unable to handle the long dependencies list for libgmp.la. The symptom is a "syntax error" on the following line of the top-level Makefile.

libgmp.la: \$(libgmp_la_OBJECTS) \$(libgmp_la_DEPENDENCIES)

Either use GNU Make, or as a workaround remove \$(libgmp_la_DEPENDENCIES) from that line (which will make the initial build work, but if any recompiling is done libgmp.la might not be rebuilt).

MacOS X ('\*-\*-darwin\*')

Libtool currently only knows how to create shared libraries on MacOS X using the native cc (which is a modified GCC), not a plain GCC. A static-only build should work though ('--disable-shared').

NeXT prior to 3.3

The system compiler on old versions of NeXT was a massacred and old GCC, even if it called itself cc. This compiler cannot be used to build GMP, you need to get a real GCC, and install that. (NeXT may have fixed this in release 3.3 of their system.)

POWER and PowerPC

Bugs in GCC 2.7.2 (and 2.6.3) mean it can't be used to compile GMP on POWER or PowerPC. If you want to use GCC for these machines, get GCC 2.7.2.1 (or later).

Sequent Symmetry

Use the GNU assembler instead of the system assembler, since the latter has serious bugs.

Solaris 2.6 The system sed prints an error "Output line too long" when libtool builds libgmp.la. This doesn't seem to cause any obvious ill effects, but GNU sed is recommended, to avoid any doubt.

Sparc Solaris 2.7 with gcc 2.95.2 in 'ABI=32'

A shared library build of GMP seems to fail in this combination, it builds but then fails the tests, apparently due to some incorrect data relocations within gmp_randinit_lc_2exp_size. The exact cause is unknown, '--disable-shared' is recommended.

## 2.6 Performance optimization

For optimal performance, build GMP for the exact CPU type of the target computer, see Section 2.1 \[Build Options\], page 3.

Unlike what is the case for most other programs, the compiler typically doesn't matter much, since GMP uses assembly language for the most critical operation.

In particular for long-running GMP applications, and applications demanding extremely large numbers, building and running the tuneup program in the tune subdirectory can be important. For example,

cd tune make tuneup

./tuneup will generate better contents for the gmp-mparam.h parameter file.

To use the results, put the output in the file indicated in the 'Parametersfor...' header. Then recompile from scratch.

The tuneup program takes one useful parameter, '-fNNN', which instructs the program how long to check FFT multiply parameters. If you're going to use GMP for extremely large numbers, you may want to run tuneup with a large NNN value.

# 3 GMP Basics

Using functions, macros, data types, etc. not documented in this manual is strongly discouraged. If you do so your application is guaranteed to be incompatible with future versions of GMP.

## 3.1 Headers and Libraries

All declarations needed to use GMP are collected in the include file gmp.h, except for the Chapter 12 \[C++ Class Interface\], page 83 which comes with its own separate header gmpxx.h. gmp.h is designed to work with both C and C++ compilers.

# include &lt;gmp.h&gt;

Note however that prototypes for GMP functions with FILE\* parameters are only provided if &lt;stdio.h&gt; is included before.

# include &lt;stdio.h&gt;

# include &lt;gmp.h&gt;

Likewise &lt;stdarg.h&gt; is required for prototypes with va*list parameters, such as gmp_vprintf. And &lt;obstack.h&gt; for prototypes with structobstack parameters, such as gmp_obstack* printf, when available.

All programs using GMP must link against the libgmp library. On a typical Unix-like system this can be done with '-lgmp', for example gcc myprogram.c -lgmp

GMP C++ functions are in a separate libgmpxx library, including the Chapter 12 \[C++ Class Interface\], page 83 but also Section 10.3 \[C++ Formatted Output\], page 77 for regular GMP types. This is built and installed if C++ support has been enabled (see Section 2.1 \[Build Options\], page 3). For example, g++ mycxxprog.cc -lgmpxx -lgmp

GMP is built using Libtool and an application can use that to link if desired, see _GNU Libtool_.

If GMP has been installed to a non-standard location then it may be necessary to use '-I' and '-L' compiler options to point to the right directories, and some sort of run-time path for a shared library.

## 3.2 Nomenclature and Types

In this manual, _integer_ usually means a multiple precision integer, as defined by the GMP library. The C data type for such integers is mpz_t. Here are some examples of how to declare such integers:

mpz_t sum; struct foo { mpz_t x, y; }; mpz_t vec\[20\];

_Rational number_ means a multiple precision fraction. The C data type for these fractions is mpq_t. For example: mpq_t quotient;

_Floating point number_ or _Float_ for short, is an arbitrary precision mantissa with a limited precision exponent. The C data type for such objects is mpf_t. For example:

mpf_t fp;

The floating point functions accept and return exponents in the C type mp_exp_t. Currently this is usually a long, but on some systems it's an int for efficiency.

A _limb_ means the part of a multi-precision number that fits in a single machine word. (We chose this word because a limb of the human body is analogous to a digit, only larger, and containing several digits.) Normally a limb is 32 or 64 bits. The C data type for a limb is mp_limb_t.

Counts of limbs of a multi-precision number represented in the C type mp_size_t. Currently this is normally a long, but on some systems it's an int for efficiency, and on some systems it will be longlong in the future.

Counts of bits of a multi-precision number are represented in the C type mp_bitcnt_t. Currently this is always an unsignedlong, but on some systems it will be an unsignedlonglong in the future.

_Random state_ means an algorithm selection and current state data. The C data type for such objects is gmp_randstate_t. For example:

gmp_randstate_t rstate;

Also, in general mp_bitcnt_t is used for bit counts and ranges, and size_t is used for byte or character counts.

Internally, GMP data types such as mpz_t are defined as one-element arrays, whose element type is part of the GMP internals (see Chapter 16 \[Internals\], page 122).

When an array is used as a function argument in C, it is not passed by value, instead its value is a pointer to the first element. In C jargon, this is sometimes referred to as the array "decaying" to a pointer. For GMP types like mpz_t, that means that the function called gets a pointer to the caller's mpz_t value, which is why no explicit & operator is needed when passing output arguments (see Section 3.5 \[Parameter Conventions\], page 20).

GMP defines names for these pointer types, e.g., mpz_ptr corresponding to mpz_t, and mpz_srcptr corresponding to constmpz_t. Most functions don't need to use these pointer types directly; it works fine to declare a function using the mpz_t or constmpz_t as the argument types, the same "pointer decay" happens in the background regardless.

Occasionally, it is useful to manipulate pointers directly, e.g., to conditionally swap _references_ to a function's inputs without changing the _values_ as seen by the caller, or returning a pointer to an mpz_t which is part of a larger structure. For these cases, the pointer types are necessary. And a mpz_ptr can be passed as argument to any GMP function declared to take an mpz_t argument.

Their definition is equivalent to the following code, which is given for illustratory purposes only:

typedef foo_internal foo_t\[1\]; typedef foo_internal \* foo_ptr; typedef const foo_internal \* foo_srcptr;

The following pointer types are defined by GMP:

- mpz_ptr for pointers to the element type in mpz_t
- mpz_srcptr for const pointers to the element type in mpz_t
- mpq_ptr for pointers to the element type in mpq_t
- mpq_srcptr for const pointers to the element type in mpq_t
- mpf_ptr for pointers to the element type in mpf_t
- mpf_srcptr for const pointers to the element type in mpf_t
- gmp_randstate_ptr for pointers to the element type in gmp_randstate_t
- gmp_randstate_srcptr for const pointers to the element type in gmp_randstate_t

## 3.3 Function Classes

There are six classes of functions in the GMP library:

- Functions for signed integer arithmetic, with names beginning with mpz\_. The associated type is mpz_t. There are about 150 functions in this class. (see Chapter 5 \[Integer Functions\], page 31)
- Functions for rational number arithmetic, with names beginning with mpq\_. The associated type is mpq_t. There are about 35 functions in this class, but the integer functions can be used for arithmetic on the numerator and denominator separately. (see Chapter 6 \[Rational Number Functions\], page 47)
- Functions for floating-point arithmetic, with names beginning with mpf\_. The associated type is mpf_t. There are about 70 functions in this class. (see Chapter 7 \[Floating-point Functions\], page 52)
- Fast low-level functions that operate on natural numbers. These are used by the functionsin the preceding groups, and you can also call them directly from very time-critical user programs. These functions' names begin with mpn*. The associated type is array of mp* limb_t. There are about 60 (hard-to-use) functions in this class. (see Chapter 8 \[Low-level Functions\], page 60)
- Miscellaneous functions. Functions for setting up custom allocation and functions for generating random numbers. (see Chapter 13 \[Custom Allocation\], page 92, and see Chapter 9 \[Random Number Functions\], page 72)

## 3.4 Variable Conventions

GMP functions generally have output arguments before input arguments. This notation is by analogy with the assignment operator.

GMP lets you use the same variable for both input and output in one call. For example, the main function for integer multiplication, mpz_mul, can be used to square x and put the result back in x with mpz_mul (x, x, x);

Before you can assign to a GMP variable, you need to initialize it by calling one of the special initialization functions. When you're done with a variable, you need to clear it out, using one of the functions for that purpose. Which function to use depends on the type of variable. See the chapters on integer functions, rational number functions, and floating-point functions for details.

A variable should only be initialized once, or at least cleared between each initialization. After a variable has been initialized, it may be assigned to any number of times.

For efficiency reasons, avoid excessive initializing and clearing. In general, initialize near the start of a function and clear near the end. For example,

void foo (void)

{

mpz_t n; int i;

mpz_init (n);

for (i = 1; i < 100; i++)

{ mpz_mul (n, ...); mpz_fdiv_q (n, ...); ...

} mpz_clear (n);

}

GMP types like mpz_t are implemented as one-element arrays of certain structures. Declaring a variable creates an object with the fields GMP needs, but variables are normally manipulated by using the pointer to the object. The appropriate pointer types (Section 3.2 \[Nomenclature and Types\], page 17) may be used to explicitly manipulate the pointer. For both behavior and efficiency reasons, it is discouraged to make copies of the GMP object itself (either directly or via aggregate objects containing such GMP objects). If copies are done, all of them must be used read-only; using a copy as the output of some function will invalidate all the other copies. Note that the actual fields in each mpz_t etc are for internal use only and should not be accessed directly by code that expects to be compatible with future GMP releases.

## 3.5 Parameter Conventions

When a GMP variable is used as a function parameter, it's effectively a call-by-reference, meaning that when the function stores a value there it will change the original in the caller. Parameters which are input-only can be designated const to provoke a compiler error or warning on attempting to modify them.

When a function is going to return a GMP result, it should designate a parameter that it sets, like the library functions do. More than one value can be returned by having more than one output parameter, again like the library functions. A return of an mpz_t etc doesn't return the object, only a pointer, and this is almost certainly not what's wanted.

Here's an example accepting an mpz_t parameter, doing a calculation, and storing the result to the indicated parameter.

void foo (mpz_t result, const mpz_t param, unsigned long n)

{ unsigned long i; mpz_mul_ui (result, param, n); for (i = 1; i < n; i++)

mpz_add_ui (result, result, i\*7);

}

int main (void)

{

mpz_t r, n;

mpz_init (r);

mpz_init_set_str (n, "123456", 0); foo (r, n, 20L); gmp_printf ("%Zd\\n", r); return 0;

}

Our function foo works even if its caller passes the same variable for param and result, just like the library functions. But sometimes it's tricky to make that work, and an application might not want to bother supporting that sort of thing.

Since GMP types are implemented as one-element arrays, using a GMP variable as a parameter passes a pointer to the object. Hence the call-by-reference. A more explicit (and equivalent) prototype for our function foo could be:

void foo (mpz_ptr result, mpz_srcptr param, unsigned long n);

## 3.6 Memory Management

The GMP types like mpz_t are small, containing only a couple of sizes, and pointers to allocated data. Once a variable is initialized, GMP takes care of all space allocation. Additional space is allocated whenever a variable doesn't have enough.

mpz_t and mpq_t variables never reduce their allocated space. Normally this is the best policy, since it avoids frequent reallocation. Applications that need to return memory to the heap at some particular point can use mpz_realloc2, or clear variables no longer needed.

mpf_t variables, in the current implementation, use a fixed amount of space, determined by the chosen precision and allocated at initialization, so their size doesn't change.

All memory is allocated using malloc and friends by default, but this can be changed, see Chapter 13 \[Custom Allocation\], page 92. Temporary memory on the stack is also used (via alloca), but this can be changed at build-time if desired, see Section 2.1 \[Build Options\], page 3.

## 3.7 Reentrancy

GMP is reentrant and thread-safe, with some exceptions:

- If configured with --enable-alloca=malloc-notreentrant (or with --enablealloca=notreentrant when alloca is not available), then naturally GMP is not reentrant.
- mpf_set_default_prec and mpf_init use a global variable for the selected precision. mpf_init2 can be used instead, and in the C++ interface an explicit precision to the mpf_class constructor.
- mpz_random and the other old random number functions use a global random state and are hence not reentrant. The newer random number functions that accept a gmp_randstate_t parameter can be used instead.
- gmp*randinit (obsolete) returns an error indication through a global variable, which is not thread safe. Applications are advised to use gmp_randinit_default or gmp_randinit_lc* 2exp instead.
- mp_set_memory_functions uses global variables to store the selected memory allocation functions.
- If the memory allocation functions set by a call to mp_set_memory_functions (or malloc and friends by default) are not reentrant, then GMP will not be reentrant either.
- If the standard I/O functions such as fwrite are not reentrant then the GMP I/O functions using them will not be reentrant either.
- It's safe for two threads to read from the same GMP variable simultaneously, but it's not safe for one to read while another might be writing, nor for two threads to write simultaneously. It's not safe for two threads to generate a random number from the same gmp_randstate_t simultaneously, since this involves an update of that variable.

## 3.8 Useful Macros and Constants

const int mp_bits_per_limb \[Global Constant\]

The number of bits per limb.

\_\_GNU_MP_VERSION \[Macro\]

\_\_GNU_MP_VERSION_MINOR \[Macro\]

\_\_GNU_MP_VERSION_PATCHLEVEL \[Macro\]

The major and minor GMP version, and patch level, respectively, as integers. For GMP i.j, these numbers will be i, j, and 0, respectively. For GMP i.j.k, these numbers will be i, j, and k, respectively.

const char \* const gmp_version \[Global Constant\]

The GMP version number, as a null-terminated string, in the form "i.j.k". This release is "6.3.0". Note that the format "i.j" was used, before version 4.3.0, when k was zero.

\_\_GMP_CC \[Macro\]

\_\_GMP_CFLAGS \[Macro\]

The compiler and compiler flags, respectively, used when compiling GMP, as strings.

## 3.9 Compatibility with older versions

This version of GMP is upwardly binary compatible with all 5.x, 4.x, and 3.x versions, and upwardly compatible at the source level with all 2.x versions, with the following exceptions.

- mpn_gcd had its source arguments swapped as of GMP 3.0, for consistency with other mpn functions.
- mpf_get_prec counted precision slightly differently in GMP 3.0 and 3.0.1, but in 3.1 reverted to the 2.x style.
- mpn_bdivmod, documented as preliminary in GMP 4, has been removed.

There are a number of compatibility issues between GMP 1 and GMP 2 that of course also apply when porting applications from GMP 1 to GMP 5. Please see the GMP 2 manual for details.

## 3.10 Demonstration programs

The demos subdirectory has some sample programs using GMP. These aren't built or installed, but there's a Makefile with rules for them. For instance,

make pexpr

./pexpr 68^975+10

The following programs are provided

- 'pexpr' is an expression evaluator, the program used on the GMP web page.
- The 'calc' subdirectory has a similar but simpler evaluator using lex and yacc.
- The 'expr' subdirectory is yet another expression evaluator, a library designed for ease of use within a C program. See demos/expr/README for more information.
- 'factorize' is a Pollard-Rho factorization program.
- 'isprime' is a command-line interface to the mpz_probab_prime_p function.
- 'primes' counts or lists primes in an interval, using a sieve.
- 'qcn' is an example use of mpz_kronecker_ui to estimate quadratic class numbers.
- The 'perl' subdirectory is a comprehensive perl interface to GMP. See demos/perl/INSTALL for more information. Documentation is in POD format in demos/perl/GMP.pm.

As an aside, consideration has been given at various times to some sort of expression evaluation within the main GMP library. Going beyond something minimal quickly leads to matters like user-defined functions, looping, fixnums for control variables, etc, which are considered outside the scope of GMP (much closer to language interpreters or compilers, See Chapter 14 \[Language Bindings\], page 94). Something simple for program input convenience may yet be a possibility, a combination of the expr demo and the pexpr tree back-end perhaps. But for now the above evaluators are offered as illustrations.

## 3.11 Efficiency

Small Operands

On small operands, the time for function call overheads and memory allocation can be significant in comparison to actual calculation. This is unavoidable in a general purpose variable precision library, although GMP attempts to be as efficient as it can on both large and small operands.

Static Linking

On some CPUs, in particular the x86s, the static libgmp.a should be used for maximum speed, since the PIC code in the shared libgmp.so will have a small overhead on each function call and global data address. For many programs this will be insignificant, but for long calculations there's a gain to be had.

Initializing and Clearing

Avoid excessive initializing and clearing of variables, since this can be quite time consuming, especially in comparison to otherwise fast operations like addition.

A language interpreter might want to keep a free list or stack of initialized variables ready for use. It should be possible to integrate something like that with a garbage collector too.

Reallocations

An mpz_t or mpq_t variable used to hold successively increasing values will have its memory repeatedly realloced, which could be quite slow or could fragment memory, depending on the C library. If an application can estimate the final size then mpz_init2 or mpz_realloc2 can be called to allocate the necessary space from the beginning (see Section 5.1 \[Initializing Integers\], page 31).

It doesn't matter if a size set with mpz_init2 or mpz_realloc2 is too small, since all functions will do a further reallocation if necessary. Badly overestimating memory required will waste space though.

2exp Functions

It's up to an application to call functions like mpz_mul_2exp when appropriate. General purpose functions like mpz_mul make no attempt to identify powers of two or other special forms, because such inputs will usually be very rare and testing every time would be wasteful.

ui and si Functions

The ui functions and the small number of si functions exist for convenience and should be used where applicable. But if for example an mpz_t contains a value that fits in an unsignedlong there's no need to extract it and call a ui function, just use the regular mpz function.

In-Place Operations

mpz_abs, mpq_abs, mpf_abs, mpz_neg, mpq_neg and mpf_neg are fast when used for in-place operations like mpz_abs(x,x), since in the current implementation only a single field of x needs changing. On suitable compilers (GCC for instance) this is inlined too.

mpz_add_ui, mpz_sub_ui, mpf_add_ui and mpf_sub_ui benefit from an in-place operation like mpz_add_ui(x,x,y), since usually only one or two limbs of x will need to be changed. The same applies to the full precision mpz_add etc if y is small. If y is big then cache locality may be helped, but that's all.

mpz_mul is currently the opposite, a separate destination is slightly better. A call like mpz_mul(x,x,y) will, unless y is only one limb, make a temporary copy of x before forming the result. Normally that copying will only be a tiny fraction of the time for the multiply, so this is not a particularly important consideration.

mpz_set, mpq_set, mpq_set_num, mpf_set, etc, make no attempt to recognise a copy of something to itself, so a call like mpz_set(x,x) will be wasteful. Naturally that would never be written deliberately, but if it might arise from two pointers to the same object then a test to avoid it might be desirable.

if (x != y)

mpz_set (x, y);

Note that it's never worth introducing extra mpz_set calls just to get in-place operations. If a result should go to a particular variable then just direct it there and let GMP take care of data movement.

Divisibility Testing (Small Integers)

mpz_divisible_ui_p and mpz_congruent_ui_p are the best functions for testing whether an mpz_t is divisible by an individual small integer. They use an algorithm which is faster than mpz_tdiv_ui, but which gives no useful information about the actual remainder, only whether it's zero (or a particular value).

However when testing divisibility by several small integers, it's best to take a remainder modulo their product, to save multi-precision operations. For instance to test whether a number is divisible by 23, 29 or 31 take a remainder modulo 23 × 29 × 31 = 20677 and then test that.

The division functions like mpz*tdiv_q_ui which give a quotient as well as a remainder are generally a little slower than the remainder-only functions like mpz* tdiv_ui. If the quotient is only rarely wanted then it's probably best to just take a remainder and then go back and calculate the quotient if and when it's wanted (mpz_divexact_ui can be used if the remainder is zero).

Rational Arithmetic

The mpq functions operate on mpq_t values with no common factors in the numerator and denominator. Common factors are checked-for and cast out as necessary. In general, cancelling factors every time is the best approach since it minimizes the sizes for subsequent operations.

However, applications that know something about the factorization of the values they're working with might be able to avoid some of the GCDs used for canonicalization, or swap them for divisions. For example when multiplying by a prime it's enough to check for factors of it in the denominator instead of doing a full GCD. Or when forming a big product it might be known that very little cancellation will be possible, and so canonicalization can be left to the end.

The mpq_numref and mpq_denref macros give access to the numerator and denominator to do things outside the scope of the supplied mpq functions. See Section 6.5 \[Applying Integer Functions\], page 49.

The canonical form for rationals allows mixed-type mpq_t and integer additions or subtractions to be done directly with multiples of the denominator. This will be somewhat faster than mpq_add. For example,

/\* mpq increment \*/ mpz_add (mpq_numref(q), mpq_numref(q), mpq_denref(q));

/\* mpq += unsigned long \*/ mpz_addmul_ui (mpq_numref(q), mpq_denref(q), 123UL);

/\* mpq -= mpz \*/

mpz_submul (mpq_numref(q), mpq_denref(q), z);

Number Sequences

Functions like mpz_fac_ui, mpz_fib_ui and mpz_bin_uiui are designed for calculating isolated values. If a range of values is wanted it's probably best to get a starting point and iterate from there.

Text Input/Output

Hexadecimal or octal are suggested for input or output in text form. Power-of2 bases like these can be converted much more efficiently than other bases, like decimal. For big numbers there's usually nothing of particular interest to be seen in the digits, so the base doesn't matter much.

Maybe we can hope octal will one day become the normal base for everyday use, as proposed by King Charles XII of Sweden and later reformers.

## 3.12 Debugging

Stack Overflow

Depending on the system, a segmentation violation or bus error might be the only indication of stack overflow. See '--enable-alloca' choices in Section 2.1 \[Build Options\], page 3, for how to address this.

In new enough versions of GCC, '-fstack-check' may be able to ensure an overflow is recognised by the system before too much damage is done, or

'-fstack-limit-symbol' or '-fstack-limit-register' may be able to add checking if the system itself doesn't do any (see Section "Options for Code Generation" in _Using the GNU Compiler Collection (GCC)_). These options must be added to the 'CFLAGS' used in the GMP build (see Section 2.1 \[Build Options\], page 3), adding them just to an application will have no effect. Note also they're a slowdown, adding overhead to each function call and each stack allocation.

Heap Problems

The most likely cause of application problems with GMP is heap corruption. Failing to init GMP variables will have unpredictable effects, and corruption arising elsewhere in a program may well affect GMP. Initializing GMP variables more than once or failing to clear them will cause memory leaks.

In all such cases a malloc debugger is recommended. On a GNU or BSD system the standard C library malloc has some diagnostic facilities, see Section "Allocation Debugging" in _The GNU C Library Reference Manual_, or 'man3malloc'. Other possibilities, in no particular order, include

<http://cs.ecs.baylor.edu/~donahoo/tools/ccmalloc/>

<http://dmalloc.com/>

<https://wiki.gnome.org/Apps/MemProf>

The GMP default allocation routines in memory.c also have a simple sentinel scheme which can be enabled with #defineDEBUG in that file. This is mainly designed for detecting buffer overruns during GMP development, but might find other uses.

Stack Backtraces

On some systems the compiler options GMP uses by default can interfere with debugging. In particular on x86 and 68k systems '-fomit-frame-pointer' is used and this generally inhibits stack backtracing. Recompiling without such options may help while debugging, though the usual caveats about it potentially moving a memory problem or hiding a compiler bug will apply.

GDB, the GNU Debugger

A sample .gdbinit is included in the distribution, showing how to call some undocumented dump functions to print GMP variables from within GDB. Note that these functions shouldn't be used in final application code since they're undocumented and may be subject to incompatible changes in future versions of GMP.

Source File Paths

GMP has multiple source files with the same name, in different directories. For example mpz, mpq and mpf each have an init.c. If the debugger can't already determine the right one it may help to build with absolute paths on each C file. One way to do that is to use a separate object directory with an absolute path to the source directory.

cd /my/build/dir

/my/source/dir/gmp-6.3.0/configure

This works via VPATH, and might require GNU make. Alternately it might be possible to change the .c.lo rules appropriately.

Assertion Checking

The build option --enable-assert is available to add some consistency checks to the library (see Section 2.1 \[Build Options\], page 3). These are likely to be of limited value to most applications. Assertion failures are just as likely to indicate memory corruption as a library or compiler bug.

Applications using the low-level mpn functions, however, will benefit from --enableassert since it adds checks on the parameters of most such functions, many of which have subtle restrictions on their usage. Note however that only the generic C code has checks, not the assembly code, so --disable-assembly should be used for maximum checking.

Temporary Memory Checking

The build option --enable-alloca=debug arranges that each block of temporary memory in GMP is allocated with a separate call to malloc (or the allocation function set with mp_set_memory_functions).

This can help a malloc debugger detect accesses outside the intended bounds, or detect memory not released. In a normal build, on the other hand, temporary memory is allocated in blocks which GMP divides up for its own use, or may be allocated with a compiler builtin alloca which will go nowhere near any malloc debugger hooks.

Maximum Debuggability

To summarize the above, a GMP build for maximum debuggability would be

./configure --disable-shared --enable-assert \\

\--enable-alloca=debug --disable-assembly CFLAGS=-g

For C++, add '--enable-cxxCXXFLAGS=-g'.

| Checker  | The GCC checker (<https://savannah.nongnu.org/projects/checker/>) can be used with GMP. It contains a stub library which means GMP applications compiled with checker can use a normal GMP build.<br><br>A build of GMP with checking within GMP itself can be made. This will run very very slowly. On GNU/Linux for example,<br><br>./configure --disable-assembly CC=checkergcc<br><br>\--disable-assembly must be used, since the GMP assembly code doesn't support the checking scheme. The GMP C++ features cannot be used, since current versions of checker (0.9.9.1) don't yet support the standard C++ library. |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Valgrind | Valgrind (<http://valgrind.org/>) is a memory checker for x86, ARM, MIPS, PowerPC, and S/390. It translates and emulates machine instructions to do strong checks for uninitialized data (at the level of individual bits), memory accesses through bad pointers, and memory leaks.                                                                                                                                                                                                                                                                                                                                       |

Valgrind does not always support every possible instruction, in particular ones recently added to an ISA. Valgrind might therefore be incompatible with a recent GMP or even a less recent GMP which is compiled using a recent GCC.

GMP's assembly code sometimes promotes a read of the limbs to some larger size, for efficiency. GMP will do this even at the start and end of a multilimb operand, using naturally aligned operations on the larger type. This may lead to benign reads outside of allocated areas, triggering complaints from Valgrind. Valgrind's option '--partial-loads-ok=yes' should help.

Other Problems

Any suspected bug in GMP itself should be isolated to make sure it's not an application problem, see Chapter 4 \[Reporting Bugs\], page 30.

## 3.13 Profiling

Running a program under a profiler is a good way to find where it's spending most time and where improvements can be best sought. The profiling choices for a GMP build are as follows.

'--disable-profiling'

The default is to add nothing special for profiling.

It should be possible to just compile the mainline of a program with -p and use prof to get a profile consisting of timer-based sampling of the program counter. Most of the GMP assembly code has the necessary symbol information.

This approach has the advantage of minimizing interference with normal program operation, but on most systems the resolution of the sampling is quite low (10 milliseconds for instance), requiring long runs to get accurate information.

'--enable-profiling=prof'

Build with support for the system prof, which means '-p' added to the 'CFLAGS'.

This provides call counting in addition to program counter sampling, which allows the most frequently called routines to be identified, and an average time spent in each routine to be determined.

The x86 assembly code has support for this option, but on other processors the assembly routines will be as if compiled without '-p' and therefore won't appear in the call counts.

On some systems, such as GNU/Linux, '-p' in fact means '-pg' and in this case '--enable-profiling=gprof' described below should be used instead. '--enable-profiling=gprof'

Build with support for gprof, which means '-pg' added to the 'CFLAGS'.

This provides call graph construction in addition to call counting and program counter sampling, which makes it possible to count calls coming from different locations. For example the number of calls to mpn_mul from mpz_mul versus the number from mpf_mul. The program counter sampling is still flat though, so only a total time in mpn_mul would be accumulated, not a separate amount for each call site.

The x86 assembly code has support for this option, but on other processors the assembly routines will be as if compiled without '-pg' and therefore not be included in the call counts.

On x86 and m68k systems '-pg' and '-fomit-frame-pointer' are incompatible, so the latter is omitted from the default flags in that case, which might result in poorer code generation.

Incidentally, it should be possible to use the gprof program with a plain '--enable-profiling=prof' build. But in that case only the 'gprof-p' flat profile and call counts can be expected to be valid, not the 'gprof-q' call graph.

'--enable-profiling=instrument'

Build with the GCC option '-finstrument-functions' added to the 'CFLAGS' (see Section "Options for Code Generation" in _Using the GNU Compiler Collection (GCC)_).

This inserts special instrumenting calls at the start and end of each function, allowing exact timing and full call graph construction.

This instrumenting is not normally a standard system feature and will require support from an external library, such as

<https://sourceforge.net/projects/fnccheck/>

This should be included in 'LIBS' during the GMP configure so that test programs will link. For example,

./configure --enable-profiling=instrument LIBS=-lfc

On a GNU system the C library provides dummy instrumenting functions, so programs compiled with this option will link. In this case it's only necessary to ensure the correct library is added when linking an application.

The x86 assembly code supports this option, but on other processors the assembly routines will be as if compiled without '-finstrument-functions' meaning time spent in them will effectively be attributed to their caller.

## 3.14 Autoconf

Autoconf based applications can easily check whether GMP is installed. The only thing to be noted is that GMP library symbols from version 3 onwards have prefixes like \_\_gmpz. The following therefore would be a simple test,

AC_CHECK_LIB(gmp, \_\_gmpz_init)

This just uses the default AC_CHECK_LIB actions for found or not found, but an application that must have GMP would want to generate an error if not found. For example,

AC_CHECK_LIB(gmp, \_\_gmpz_init, ,

\[AC_MSG_ERROR(\[GNU MP not found, see <https://gmplib.org/\])\>])

If functions added in some particular version of GMP are required, then one of those can be used when checking. For example mpz_mul_si was added in GMP 3.1,

AC_CHECK_LIB(gmp, \_\_gmpz_mul_si, ,

\[AC_MSG_ERROR(

\[GNU MP not found, or not 3.1 or up, see <https://gmplib.org/\])\>])

An alternative would be to test the version number in gmp.h using say AC_EGREP_CPP. That would make it possible to test the exact version, if some particular sub-minor release is known to be necessary.

In general it's recommended that applications should simply demand a new enough GMP rather than trying to provide supplements for features not available in past versions.

Occasionally an application will need or want to know the size of a type at configuration or preprocessing time, not just with sizeof in the code. This can be done in the normal way with mp_limb_t etc, but GMP 4.0 or up is best for this, since prior versions needed certain '-D' defines on systems using a longlong limb. The following would suit Autoconf 2.50 or up,

AC_CHECK_SIZEOF(mp_limb_t, , \[#include &lt;gmp.h&gt;\])

## 3.15 Emacs

C-h C-i (info-lookup-symbol) is a good way to find documentation on C functions while editing (see Section "Info Documentation Lookup" in _The Emacs Editor_).

The GMP manual can be included in such lookups by putting the following in your .emacs,

(eval-after-load "info-look"

'(let ((mode-value (assoc 'c-mode (assoc 'symbol info-lookup-alist)))) (setcar (nthcdr 3 mode-value)

(cons '("(gmp)Function Index" nil "^ -.\* " "\\\\>")

(nth 3 mode-value)))))

# 4 Reporting Bugs

If you think you have found a bug in the GMP library, please investigate it and report it. We have made this library available to you, and it is not too much to ask you to report the bugs you find.

Before you report a bug, check it's not already addressed in Section 2.5 \[Known Build Problems\], page 14, or perhaps Section 2.4 \[Notes for Particular Systems\], page 12. You may also want to check <https://gmplib.org/> for patches for this release, or try a recent snapshot from [https:// gmplib.org/download/snapshot/](https://gmplib.org/download/snapshot/).

Please include the following in any report:

- The GMP version number, and if pre-packaged or patched then say so.
- A test program that makes it possible for us to reproduce the bug. Include instructions on how to run the program.
- A description of what is wrong. If the results are incorrect, in what way. If you get a crash, say so.
- If you get a crash, include a stack backtrace from the debugger if it's informative ('where' in gdb, or '\$C' in adb).
- Please do not send core dumps, executables or straces.
- The 'configure' options you used when building GMP, if any.
- The output from 'configure', as printed to stdout, with any options used.
- The name of the compiler and its version. For gcc, get the version with 'gcc-v', otherwise perhaps 'what'whichcc'', or similar.
- The output from running 'uname-a'.
- The output from running './config.guess', and from running './configfsf.guess' (might be the same).
- If the bug is related to 'configure', then the compressed contents of config.log.
- If the bug is related to an asm file not assembling, then the contents of config.m4 and the offending line or lines from the temporary mpn/tmp-&lt;file&gt;.s.

Please make an effort to produce a self-contained report, with something definite that can be tested or debugged. Vague queries or piecemeal messages are difficult to act on and don't help the development effort.

It is not uncommon that an observed problem is actually due to a bug in the compiler; the GMP code tends to explore interesting corners in compilers.

If your bug report is good, we will do our best to help you get a corrected version of the library; if the bug report is poor, we won't do anything about it (except maybe ask you to send a better report).

Send your report to: <gmp-bugs@gmplib.org>.

If you think something in this manual is unclear, or downright incorrect, or if the language needs to be improved, please send a note to the same address.

# 5 Integer Functions

This chapter describes the GMP functions for performing integer arithmetic. These functions start with the prefix mpz\_.

GMP integers are stored in objects of type mpz_t.

## 5.1 Initialization Functions

The functions for integer arithmetic assume that all integer objects are initialized. You do that by calling the function mpz_init. For example,

{ mpz_t integ; mpz_init (integ); ...

mpz_add (integ, ...); ... mpz_sub (integ, ...);

/\* Unless the program is about to exit, do ... \*/ mpz_clear (integ);

}

As you can see, you can store new values any number of times, once an object is initialized.

void mpz*init (\_mpz t x*) \[Function\]

Initialize _x_, and set its value to 0.

void mpz*inits (\_mpz t x, ...*) \[Function\]

Initialize a NULL-terminated list of mpz_t variables, and set their values to 0.

void mpz*init2 (\_mpz t x, mp bitcnt t n*) \[Function\]

Initialize _x_, with space for _n_\-bit numbers, and set its value to 0. Calling this function instead of mpz_init or mpz_inits is never necessary; reallocation is handled automatically by GMP when needed.

While _n_ defines the initial space, _x_ will grow automatically in the normal way, if necessary, for subsequent values stored. mpz_init2 makes it possible to avoid such reallocations if a maximum size is known in advance.

In preparation for an operation, GMP often allocates one limb more than ultimately needed. To make sure GMP will not perform reallocation for _x_, you need to add the number of bits in mp*limb_t to \_n*.

void mpz*clear (\_mpz t x*) \[Function\]

Free the space occupied by _x_. Call this function for all mpz_t variables when you are done with them.

void mpz*clears (\_mpz t x, ...*) \[Function\]

Free the space occupied by a NULL-terminated list of mpz_t variables.

void mpz*realloc2 (\_mpz t x, mp bitcnt t n*) \[Function\]

Change the space allocated for _x_ to _n_ bits. The value in _x_ is preserved if it fits, or is set to 0 if not.

Calling this function is never necessary; reallocation is handled automatically by GMP when needed. But this function can be used to increase the space for a variable in order to avoid repeated automatic reallocations, or to decrease it to give memory back to the heap.

## 5.2 Assignment Functions

These functions assign new values to already initialized integers (see Section 5.1 \[Initializing Integers\], page 31).

void mpz*set (\_mpz t rop, const mpz t op*) \[Function\] void mpz*set_ui (\_mpz t rop, unsigned long int op*) \[Function\] void mpz*set_si (\_mpz t rop, signed long int op*) \[Function\] void mpz*set_d (\_mpz t rop, double op*) \[Function\] void mpz*set_q (\_mpz t rop, const mpqt op*) \[Function\] void mpz*set_f (\_mpz t rop, const mpft op*) \[Function\]

| Set the value of _rop_ from _op_.<br><br>mpz*set_d, mpz_set_q and mpz_set_f truncate \_op* to make it an integer. |              |
| ----------------------------------------------------------------------------------------------------------------- | ------------ |
| int mpz*set_str (\_mpz t rop, const char \*str, int base*)                                                        | \[Function\] |

Set the value of _rop_ from _str_, a null-terminated C string in base _base_. White space is allowed in the string, and is simply ignored.

The _base_ may vary from 2 to 62, or if _base_ is 0, then the leading characters are used: 0x and 0X for hexadecimal, 0b and 0B for binary, 0 for octal, or decimal otherwise.

For bases up to 36, case is ignored; upper-case and lower-case letters have the same value. For bases 37 to 62, upper-case letters represent the usual 10..35 while lower-case letters represent 36..61.

This function returns 0 if the entire string is a valid number in base _base_. Otherwise it returns −1.

void mpz*swap (\_mpz t rop1, mpz t rop2*) \[Function\]

Swap the values _rop1_ and _rop2_ efficiently.

## 5.3 Combined Initialization and Assignment Functions

For convenience, GMP provides a parallel series of initialize-and-set functions which initialize the output and then store the value there. These functions' names have the form mpz_init_set...

Here is an example of using one:

{ mpz_t pie; mpz_init_set_str (pie, "3141592653589793238462643383279502884", 10); ...

mpz_sub (pie, ...); ...

mpz_clear (pie);

}

Once the integer has been initialized by any of the mpz_init_set... functions, it can be used as the source or destination operand for the ordinary integer functions. Don't use an initializeand-set function on a variable already initialized!

void mpz*init_set (\_mpz t rop, const mpz op*)

void mpz*init_set_ui (\_mpz t rop, unsigned long int op*) \[Function\] void mpz*init_set_si (\_mpz t rop, signed long int op*) \[Function\] void mpz*init_set_d (\_mpz t rop, double op*) \[Function\]

Initialize _rop_ with limb space and set the initial numeric value from _op_.

int mpz*init_set_str (\_mpz t rop, const char \*str, int base*) \[Function\]

Initialize _rop_ and set its value like mpz_set_str (see its documentation above for details).

If the string is a correct base _base_ number, the function returns 0; if an error occurs it returns

−1. _rop_ is initialized even if an error occurs. (I.e., you have to call mpz_clear for it.)

## 5.4 Conversion Functions

This section describes functions for converting GMP integers to standard C types. Functions for converting _to_ GMP integers are described in Section 5.2 \[Assigning Integers\], page 32 and Section 5.12 \[I/O of Integers\], page 41.

unsigned long int mpz*get_ui (\_const mpz t op*) \[Function\]

Return the value of _op_ as an unsignedlong.

If _op_ is too big to fit an unsignedlong then just the least significant bits that do fit are returned. The sign of _op_ is ignored, only the absolute value is used.

signed long int mpz*get_si (\_const mpz t op*) \[Function\]

If _op_ fits into a signedlongint return the value of _op_. Otherwise return the least significant part of _op_, with the same sign as _op_.

If _op_ is too big to fit in a signedlongint, the returned result is probably not very useful. To find out if the value will fit, use the function mpz_fits_slong_p.

double mpz*get_d (\_const mpz t op*) \[Function\]

Convert _op_ to a double, truncating if necessary (i.e. rounding towards zero).

If the exponent from the conversion is too big, the result is system dependent. An infinity is returned where available. A hardware overflow trap may or may not occur.

double mpz*get_d_2exp (\_signed long int \*exp, const mpz t op*) \[Function\]

Convert _op_ to a double, truncating if necessary (i.e. rounding towards zero), and returning the exponent separately.

The return value is in the range 0*.\_5 ≤ |\_d*| _<_ 1 and the exponent is stored to \*_exp_. _d_ ∗ 2*<sup>exp</sup>* is the (truncated) _op_ value. If _op_ is zero, the return is 0*.\_0 and 0 is stored to \*\_exp*.

This is similar to the standard C frexp function (see Section "Normalization Functions" in _The GNU C Library Reference Manual_).

char \* mpz*get_str (\_char \*str, int base, const mpz t op*) \[Function\]

Convert _op_ to a string of digits in base _base_. The base argument may vary from 2 to 62 or from −2 to −36.

For _base_ in the range 2..36, digits and lower-case letters are used; for −2..−36, digits and upper-case letters are used; for 37..62, digits, upper-case letters, and lower-case letters (in that significance order) are used.

If _str_ is NULL, the result string is allocated using the current allocation function (see Chapter 13 \[Custom Allocation\], page 92). The block will be strlen(str)+1 bytes, that being exactly enough for the string and null-terminator.

If _str_ is not NULL, it should point to a block of storage large enough for the result, that being mpz*sizeinbase(\_op*,_base_)+2. The two extra bytes are for a possible minus sign, and the null-terminator.

A pointer to the result string is returned, being either the allocated block, or the given _str_.

## 5.5 Arithmetic Functions

| void mpz*add (\_mpz t rop, const mpz t op1, const mpz t op2*) void mpz*add_ui (\_mpz t rop, const mpz t op1, unsigned long int op2*)<br><br>Set _rop_ to _op1_ \+ _op2_. | \[Function\]<br><br>\[Function\] |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------- |
| void mpz*sub (\_mpz t rop, const mpz t op1, const mpz t op2*)                                                                                                            | \[Function\]                     |

void mpz*sub_ui (\_mpz t rop, const mpz t op1, unsigned long int op2*) \[Function\] void mpz*ui_sub (\_mpz t rop, unsigned long int op1, const mpz t op2*) \[Function\]

| Set _rop_ to _op1_ − _op2_.                                   |              |
| ------------------------------------------------------------- | ------------ |
| void mpz*mul (\_mpz t rop, const mpz t op1, const mpz t op2*) | \[Function\] |

void mpz*mul_si (\_mpz t rop, const mpz t op1, long int op2*) \[Function\] void mpz*mul_ui (\_mpz t rop, const mpz t op1, unsigned long int op2*) \[Function\] Set _rop_ to _op1_ × _op2_.

void mpz*addmul (\_mpz t rop, const mpz t op1, const mpz t op2*) \[Function\] void mpz*addmul_ui (\_mpz t rop, const mpz t op1, unsigned long int op2*) \[Function\] Set _rop_ to _rop_ \+ _op1_ × _op2_.

void mpz*submul (\_mpz t rop, const mpz t op1, const mpz t op2*) \[Function\] void mpz*submul_ui (\_mpz t rop, const mpz t op1, unsigned long int op2*) \[Function\] Set _rop_ to _rop_ − _op1_ × _op2_.

void mpz*mul_2exp (\_mpz t rop, const mpz t op1, mp bitcnt t op2*) \[Function\]

Set _rop_ to _op1_ × 2*<sup>op</sup>*<sup>2</sup>. This operation can also be defined as a left shift by _op2_ bits.

void mpz*neg (\_mpz t rop, const mpz t op*) \[Function\]

Set _rop_ to −*op*.

void mpz*abs (\_mpz t rop, const mpz t op*) \[Function\]

Set _rop_ to the absolute value of _op_.

## 5.6 Division Functions

Division is undefined if the divisor is zero. Passing a zero divisor to the division or modulo functions (including the modular powering functions mpz_powm and mpz_powm_ui) will cause an intentional division by zero. This lets a program handle arithmetic exceptions in these functions the same way as for normal C int arithmetic.

void mpz*cdiv_q (\_mpz t q, const mpz t n, const mpz t d*) \[Function\] void mpz*cdiv_r (\_mpz t r, const mpz t n, const mpz t d*) \[Function\] void mpz*cdiv_qr (\_mpz t q, mpz t r, const mpz t n, const mpz t d*) \[Function\] unsigned long int mpz*cdiv_q_ui (\_mpz q, const mpzt n, unsigned long int d*)

unsigned long int mpz*cdiv_r_ui (\_mpz t r, const mpzt n,* \[Function\] _unsigned long int d_)

unsigned long int mpz*cdiv_qr_ui (\_mpz t q, mpz t r, const mpz t n,* \[Function\] _unsigned long int d_)

unsigned long int mpz*cdiv_ui (\_const mpz t n, unsigned long int d*) \[Function\] void mpz*cdiv_q_2exp (\_mpzt q, const mpz t n, mp bitcnt t b*) \[Function\] void mpz*cdiv_r_2exp (\_mpzt r, const mpz t n, mp bitcnt t b*) \[Function\] void mpz*fdiv_q (\_mpz t q, const mpz t n, const mpz t d*) \[Function\] void mpz*fdiv_r (\_mpz t r, const mpz t n, const mpz t d*) \[Function\] void mpz*fdiv_qr (\_mpz t q, mpz t r, const mpz t n, const mpz t d*) \[Function\] unsigned long int mpz*fdiv_q_ui (\_mpz t q, const mpz t n,* \[Function\] _unsigned long int d_)

unsigned long int mpz*fdiv_r_ui (\_mpz t r, const mpz t n,* \[Function\] _unsigned long int d_)

unsigned long int mpz*fdiv_qr_ui (\_mpz t q, mpz t r, const mpz t n,* \[Function\] _unsigned long int d_)

unsigned long int mpz*fdiv_ui (\_const mpz t n, unsigned long int d*) \[Function\] void mpz*fdiv_q_2exp (\_mpzt q, const mpz t n, mp bitcnt t b*) \[Function\] void mpz*fdiv_r_2exp (\_mpzt r, const mpz t n, mp bitcnt t b*) \[Function\] void mpz*tdiv_q (\_mpz t q, const mpz t n, const mpz t d*) \[Function\] void mpz*tdiv_r (\_mpz t r, const mpz t n, const mpz t d*) \[Function\] void mpz*tdiv_qr (\_mpz t q, mpz t r, const mpz t n, const mpz t d*) \[Function\] unsigned long int mpz*tdiv_q_ui (\_mpz t q, const mpz t n,* \[Function\] _unsigned long int d_)

unsigned long int mpz*tdiv_r_ui (\_mpz t r, const mpz t n,* \[Function\] _unsigned long int d_)

unsigned long int mpz*tdiv_qr_ui (\_mpz t q, mpz t r, const mpz t n,* \[Function\] _unsigned long int d_)

unsigned long int mpz*tdiv_ui (\_const mpz t n, unsigned long int d*) \[Function\] void mpz*tdiv_q_2exp (\_mpzt q, const mpz t n, mp bitcnt t b*) \[Function\] void mpz*tdiv_r_2exp (\_mpzt r, const mpz t n, mp bitcnt t b*) \[Function\]

Divide _n_ by _d_, forming a quotient _q_ and/or remainder _r_. For the 2exp functions, _d_ \= 2*<sup>b</sup>*. The rounding is in three styles, each suiting different applications.

- cdiv rounds _q_ up towards +∞, and _r_ will have the opposite sign to _d_. The c stands for

"ceil".

- fdiv rounds _q_ down towards −∞, and _r_ will have the same sign as _d_. The f stands for

"floor".

- tdiv rounds _q_ towards zero, and _r_ will have the same sign as _n_. The t stands for

"truncate".

In all cases _q_ and _r_ will satisfy _n_ \= _qd_ \+ _r_, and _r_ will satisfy 0 ≤ |_r_| _<_ |_d_|.

The q functions calculate only the quotient, the r functions only the remainder, and the qr functions calculate both. Note that for qr the same variable cannot be passed for both _q_ and _r_, or results will be unpredictable.

For the ui variants the return value is the remainder, and in fact returning the remainder is all the div_ui functions do. For tdiv and cdiv the remainder can be negative, so for those the return value is the absolute value of the remainder.

For the 2exp variants the divisor is 2*<sup>b</sup>*. These functions are implemented as right shifts and bit masks, but of course they round the same as the other functions.

For positive _n_ both mpz*fdiv_q_2exp and mpz_tdiv_q_2exp are simple bitwise right shifts. For negative \_n*, mpz*fdiv_q_2exp is effectively an arithmetic right shift treating \_n* as two's complement the same as the bitwise logical functions do, whereas mpz*tdiv_q_2exp effectively treats \_n* as sign and magnitude.

void mpz*mod (\_mpz t r, const mpz t n, const mpz t d*) \[Function\] unsigned long int mpz*mod_ui (\_mpz t r, const mpz t n,* \[Function\]

_unsigned long int d_)

Set _r_ to _n_ mod _d_. The sign of the divisor is ignored; the result is always non-negative.

mpz*mod_ui is identical to mpz_fdiv_r_ui above, returning the remainder as well as setting \_r*. See mpz_fdiv_ui above if only the return value is wanted.

void mpz*divexact (\_mpz t q, const mpz t n, const mpz t d*) \[Function\] void mpz*divexact_ui (\_mpz t q, const mpz t n, unsigned long d*) \[Function\]

Set _q_ to _n_/_d_. These functions produce correct results only when it is known in advance that _d_ divides _n_.

These routines are much faster than the other division functions, and are the best choice when exact division is known to occur, for example reducing a rational to lowest terms.

int mpz*divisible_p (\_const mpz t n, const mpz t d*) \[Function\] int mpz*divisible_ui_p (\_const mpz t n, unsigned long int d*) \[Function\] int mpz*divisible_2exp_p (\_const mpz t n, mp bitcnt t b*) \[Function\]

Return non-zero if _n_ is exactly divisible by _d_, or in the case of mpz*divisible_2exp_p by 2*<sup>b</sup>\_.

_n_ is divisible by _d_ if there exists an integer _q_ satisfying _n_ \= _qd_. Unlike the other division functions, _d_ \= 0 is accepted and following the rule it can be seen that only 0 is considered divisible by 0.

int mpz*congruent_p (\_const mpz t n, const mpz t c, const mpz t d*) \[Function\] int mpz*congruent_ui_p (\_const mpz t n, unsigned long int c, unsigned long* \[Function\] _int d_)

int mpz*congruent_2exp_p (\_const mpz t n, const mpz t c, mp bitcnt t b*) \[Function\] Return non-zero if _n_ is congruent to _c_ modulo _d_, or in the case of mpz*congruent_2exp_p modulo 2*<sup>b</sup>\_.

_n_ is congruent to _c_ mod _d_ if there exists an integer _q_ satisfying _n_ \= _c_ +_qd_. Unlike the other division functions, _d_ \= 0 is accepted and following the rule it can be seen that _n_ and _c_ are considered congruent mod 0 only when exactly equal.

## 5.7 Exponentiation Functions

void mpz*powm (\_mpz t rop, const mpz t base, const mpz t exp, const mpz t* \[Function\] _mod_)

void mpz*powm_ui (\_mpz t rop, const mpz t base, unsigned long int exp,* \[Function\] _const mpz t mod_)

Set _rop_ to _base<sup>exp</sup>_ mod _mod_.

Negative _exp_ is supported if the inverse _base_ sup−1 mod _mod_ exists (see mpz_invert in Section 5.9 \[Number Theoretic Functions\], page 38). If an inverse doesn't exist then a divide by zero is raised.

void mpz*powm_sec (\_mpz t rop, const mpz base, const mpz t exp, const mpz t mod*)

Set _rop_ to _base<sup>exp</sup>_ mod _mod_.

It is required that _exp >_ 0 and that _mod_ is odd.

This function is designed to take the same time and have the same cache access patterns for any two same-size arguments, assuming that function arguments are placed at the same position and that the machine state is identical upon function entry. This function is intended for cryptographic purposes, where resilience to side-channel attacks is desired.

void mpz*pow_ui (\_mpz t rop, const mpz t base, unsigned long int exp*) \[Function\] void mpz*ui_pow_ui (\_mpz t rop, unsigned long int base, unsigned long int* \[Function\] _exp_)

Set _rop_ to _base<sup>exp</sup>_. The case 0<sup>0</sup> yields 1.

## 5.8 Root Extraction Functions

int mpz*root (\_mpz t rop, const mpz t op, unsigned long int n*) \[Function\] √

Set _rop_ to b _<sup>n</sup> op_c_,_the truncated integer part of the_n_th root of \_op_. Return non-zero if the computation was exact, i.e., if _op_ is _rop_ to the_n_th power.

void mpz*rootrem (\_mpz t root, mpz t rem, const mpz t u, unsigned long int* \[Function\]

_n_) √

Set _root_ to b _<sup>n</sup> u_c_,_the truncated integer part of the_n_th root of \_u_. Set _rem_ to the remainder, (_u_ − _root<sup>n</sup>_).

void mpz*sqrt (\_mpz t rop, const mpz t op*) \[Function\] √

Set _rop_ to b _op_c_,_ the truncated integer part of the square root of \_op_.

void mpz*sqrtrem (\_mpz t rop1, mpz t rop2, const mpz t op*) \[Function\]

Set _rop1_ to b<sup>√</sup>_op_c, like mpz_sqrt. Set \_rop2_ to the remainder (_op_ − _rop1_<sup>2</sup>), which will be zero if _op_ is a perfect square.

If _rop1_ and _rop2_ are the same variable, the results are undefined.

int mpz*perfect_power_p (\_const mpz t op*) \[Function\]

Return non-zero if _op_ is a perfect power, i.e., if there exist integers _a_ and _b_, with _b >_ 1, such that _op_ \= _a<sup>b</sup>_.

Under this definition both 0 and 1 are considered to be perfect powers. Negative values of _op_ are accepted, but of course can only be odd perfect powers.

int mpz*perfect_square_p (\_const mpz t op*) \[Function\]

Return non-zero if _op_ is a perfect square, i.e., if the square root of _op_ is an integer. Under this definition both 0 and 1 are considered to be perfect squares.

## 5.9 Number Theoretic Functions

int mpz*probab_prime_p (\_const mpz t n, int reps*) \[Function\]

Determine whether _n_ is prime. Return 2 if _n_ is definitely prime, return 1 if _n_ is probably prime (without being certain), or return 0 if _n_ is definitely non-prime.

This function performs some trial divisions, a Baillie-PSW probable prime test, then _reps-24_ Miller-Rabin probabilistic primality tests. A higher _reps_ value will reduce the chances of a non-prime being identified as "probably prime". A composite number will be identified as a prime with an asymptotic probability of less than 4<sup>−</sup>_<sup>reps</sup>_. Reasonable values of _reps_ are between 15 and 50.

GMP versions up to and including 6.1.2 did not use the Baillie-PSW primality test. In those older versions of GMP, this function performed _reps_ Miller-Rabin tests.

void mpz*nextprime (\_mpz t rop, const mpz t op*) \[Function\]

Set _rop_ to the next prime greater than _op_.

int mpz*prevprime (\_mpz t rop, const mpz t op*) \[Function\]

Set _rop_ to the greatest prime less than _op_.

If a previous prime doesn't exist (i.e. _op_ < 3), rop is unchanged and 0 is returned.

Return 1 if _rop_ is a probably prime, and 2 if _rop_ is definitely prime.

These functions use a probabilistic algorithm to identify primes. For practical purposes it's adequate, the chance of a composite passing will be extremely small.

void mpz*gcd (\_mpz t rop, const mpz t op1, const mpz t op2*) \[Function\]

Set _rop_ to the greatest common divisor of _op1_ and _op2_. The result is always positive even if one or both input operands are negative. Except if both inputs are zero; then this function defines _gcd_(0\_,_0) = 0.

unsigned long int mpz*gcd_ui (\_mpz t rop, const mpz t op1, unsigned* \[Function\] _long int op2_)

Compute the greatest common divisor of _op1_ and _op2_. If _rop_ is not NULL, store the result there.

If the result is small enough to fit in an unsignedlongint, it is returned. If the result does not fit, 0 is returned, and the result is equal to the argument _op1_. Note that the result will always fit if _op2_ is non-zero.

void mpz*gcdext (\_mpz t g, mpz t s, mpz t t, const mpz t a, const mpz t b*) \[Function\] Set _g_ to the greatest common divisor of _a_ and _b_, and in addition set _s_ and _t_ to coefficients satisfying _as_ \+ _bt_ \= _g_. The value in _g_ is always positive, even if one or both of _a_ and _b_ are negative (or zero if both inputs are zero). The values in _s_ and _t_ are chosen such that normally, |_s_| _<_ |_b_|_/_(2*g*) and |_t_| _<_ |_a_|_/_(2*g*), and these relations define _s_ and _t_ uniquely. There are a few exceptional cases:

If |_a_| = |_b_|, then _s_ \= 0, _t_ \= _sgn_(_b_).

Otherwise, _s_ \= _sgn_(_a_) if _b_ \= 0 or |_b_| = 2*g*, and _t_ \= _sgn_(_b_) if _a_ \= 0 or |_a_| = 2*g*.

In all cases, _s_ \= 0 if and only if _g_ \= |_b_|, i.e., if _b_ divides _a_ or _a_ \= _b_ \= 0.

If _t_ or _g_ is NULL then that value is not computed.

void mpz*lcm (\_mpz t rop, const mpz t op1, const mpz t op2*)

void mpz*lcm_ui (\_mpz t rop, const mpz t op1, unsigned long op2*) \[Function\]

Set _rop_ to the least common multiple of _op1_ and _op2_. _rop_ is always positive, irrespective of the signs of _op1_ and _op2_. _rop_ will be zero if either _op1_ or _op2_ is zero.

int mpz*invert (\_mpz t rop, const mpz t op1, const mpz t op2*) \[Function\]

Compute the inverse of _op1_ modulo _op2_ and put the result in _rop_. If the inverse exists, the return value is non-zero and _rop_ will satisfy 0 ≤ _rop <_ |_op2_| (with _rop_ \= 0 possible only when |_op2_| = 1, i.e., in the somewhat degenerate zero ring). If an inverse doesn't exist the return value is zero and _rop_ is undefined. The behaviour of this function is undefined when _op2_ is zero.

int mpz*jacobi (\_const mpz t a, const mpz t b*) \[Function\]

Calculate the Jacobi symbol ![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADcAAAA2CAYAAABjhwHjAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAAAQaSURBVGhD7Zq/ilQxFMY/7f2zTmc5WggrDFisIoNgI7L4AFuJYLE+gEyhNhYj+AJTCbaWYjVaioI4WFiIzWghtu6oL3Btzjd8e/bm3iQ3s+6KP7gkk9yb5OQkJ8nJAP8BAPQAbPvEfWZoTxRHfUKAPoApgKs+Y585DuAFgC2fkUsPwMyeg8A2gJ0SAlKwHdPeQWFSQsBnAKquhayAHoC5CTjwmTFsm2DPfMYBYWjtm5mw0fStV6rUDwMMAIzNKE1lJPRye96YWhtHPqMJfjT2GYn0rAw2oGfPxJ6Z5eUK2Lfvo20C1d1VazRGoTnLDqxiGxaA5URNn6SXG6AxCml/ZPlzn5HIpmivcYEfSG9u+swEtiK0P7H8ic/IgPYh1JGAVFj5jETmEdrnO3VDNhXO652Gzlz2QFOj2lDthxpOQ1B1nG9E7URtnRy7wRci4fpYNVhBDtuu801hnVMm6Mb5hsTfSzyVExL/KHHlioWvJG2zoxZfWrjBoanCXbNwAeCrpKfyzcKFS1dY12tJewjgmPxO5YOFawAuQoTrAzhj8S5ag3y/5tLJROr6bmHf3g9pOoa3Ej8PEe6cZLAHcvkK4JHFdd3hzuQUgC+SDgB3ATxwaan8lvgFiS8X1KrgaXts1ndsz1zKHljeTLZiJaAMO5qoW6HGVT6RXotrYNhgUXNQ4ZbGSYUrWdl+s0sOzrkN99K/wDEKp5aNFuyws+69XwsAP1zaoeWIhZWFCzPVOQwB3PaJGbwF8MQnRjIGcM/id5hYa0ITuSXldHme+oIT2LWkldTc2QaTn8IcwBufGMkIwGOLF9XcQYCn/wrAtjcoh52T+sMLt3bIF3HlF4XzG9l/gc8UruSJ+G9yVn9QOD3mXJJ4VwZ2EhjZ0+idKgDPiQs9G6rfo9SRB+JCp+Nplddg6nSaQTT3SV4qecF4H8B1OZ2vUrjTEt8lnC6aVG1JeOpQn0lp1iW+px769RsdmxmoH7OLd6sNdSjvqUfnXYltFGG5q7bI9GAvh74u4u8kflniXeEcVh9ladR7F6yHQ7PkxKelpBe7vwLfiV68BMvlEMq+a3b4W6OpbW5HNoymherhhrlRKT3p6aSr2AA6j+sE4aV9FwOm61vrtVupS0FIj84DArCuLjuXpPaq9lp7ogU/3zxs2PJmJgPWEb2z4nBqHMMt6Hyr0xpEuNxDMtuZ3DlNl/UxxKxvdKLmdKKOMD+XW+F/UeZ1K34EnG9N9wBsXNM7IXhVHD0cPVw/cq6RqZWQ5vUmN3Vu85o4p127oICpPUThQls57gVT5wtHVM5QroXXUSEt1MHG1wnHtSl1s8A/7hQTjGy1GAcPh47fDLCBqZ0FKytV0yuD/4uk9oYm2DxRY1nQ47xKNgHcNJ/iTwDPSxiCGP4AwgtUgcGnb5wAAAAASUVORK5CYII=). This is defined only for _b_ odd.

int mpz*legendre (\_const mpz t a, const mpz t p*) \[Function\]

Calculate the Legendre symbol ![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEEAAABOCAYAAAB/oXuQAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAAAU6SURBVHhe7ZwxbxRXEMf/CX0ss0WkKELRpbJIdE1EEDEUkTDSdaHBVeJU9w3uG/gr0CYFxaWjSGEQIo2FIgyRXIGUM4ULSMM5UQqXl2bG+t/c273dffPWe+v8pNMN7y27b+fNzJt9O2fgf3DJNlQkA/A9gI8B/Gk7G2IA4DsArwGc2s7UZAAOAMwAbNvOBtmWMezJmBqDFbBrO8+BxhXRNgUo95tUhCrgwHa0gD1SRDJU29MmtF2DDMAkpZWq380AbNrOFrFJE+UasHty0plYQ9vZlbFOZOwuqK9NbUdLyWjSxrazDgNyA1fzSgy778B2VoEDTRtXg2Xo2CcxgXzkpc1zgq1haDvLwH61ilagRFkDW8EqxQJLlDWoBme2Y8Vgi57YziJYe0kyr4bRTLdSbNO8YNby7LAsfbqfUs8VPfoPlcyn5ahLTG0W+SH/Q7hN8i8kpyATS2vC2jRzXAdwzfQtoI/KKV2hJ4OaSszZlev2JR6N6yxnS+DMt9Al2BVmttOJbbn5A3OjfbMieU9ARudecAmGV4VCbdVEZyMvcdGnv1QTwFZ+tkrYmHCL5Kcke9AD8EDkHQDvTT8A/CPfj0y7F49J/obkOdgcS6+nJdG1umjF0aV5ZDuc4LgQfBRgn5kV+UwN+NxFyZce4x0PFM4XgnFBt6X0AE94BvJukK+fEp7oPkxMuEHyc5I9+ILkVyQzev1U8UB5QfJ1GCV8RvLfJHsTCogA8K18c0AeF1hOXfj6C5bA/vEbyR48k+8T0670AdwRWY8FgK0Cy6kLK/kyjBKWppIR7AM4kpTV5gf9HKVr5phnOR5s2QYOGN4mCLnZqSyVmXxGlC5rojQUqzwIRW8HOEjPLQA2Xe5zpyM9udk9+QyNZQylfZxwDHYVPLsOd6RUQhtYuFebNiv/2oYO8dY2hJRwAuCNbewQC/emSrhq2i8SG6qENdNxkVgLuYMnOyYI1f38ZE/sSWolrASplfAzgA8cPj/aE3uSWgkrgSqBH1ouHHmWYB9yuszvISWsA/jUNnaIhYeykBK6zie2QZWwb9ovEod5lrBhGzrERySfwLgDb0B2OY3mTd8jGCXwNtYVkrvMghJekvw5yV1Dd7UB4A8YJRyT/BXJXYNzIL5nILD31tWEiZ9Og9uISw+IhDdSeUfbbsCmKhm0Ex2E3997D2RI2+1jucaAtt31LfimvLm2RRwelKq/4CIJ75J+djEuFA1dRwfr/YqeS/lyz80vJorqCKoyMCX3quxgjQCZba7J1qR0PZYeFHx/X5Nd4146mLwyW/ZdL5ewL5gKUX+dJYgLMAUbecGXfddrIviccy4YenZ4SDLXMHnxtXyfADg0fcqXJC+8J6gJ38uvJAexpW5e5qhoPCj6WY7WThUdUxWtaF3qCkqtguiSLIsHXFdUGLwqUKtgnQOT52ywleXdIP/S1QuOc3lxKAj/As4rOPESHLIwXhq93JBXhcqKZRPKTSwqovFgGhiQFnF4F2dE/44r6vdDATQejCQmTETWYu+R03WUjAJiXmK2FDbfvEBWllA86ImcFx9iibYCRWNDrDWwQpuArcC6XmV4yYqJDRoPogdUEn4YdIkxalZzhU4V4XiQGq+JmyOjm6g6k0MzK2MZWF1llkHHWioYlv3rOqdS73xPtqz/MhuzRdyV3zE8kc872dI/Du3xOTAC8IPINwuqaGujuUOMW6SEM92o1WAZGh9iVwtveDUo/XwQQ6N/yaYEHLMaUYDSJkVoLtOoAhRVRGiztCl05TkXBShtCJBRlvgfxMnbpSworwkAAAAASUVORK5CYII=). This is defined only for _p_ an odd positive prime, and for such _p_ it's identical to the Jacobi symbol.

int mpz*kronecker (\_const mpz t a, const mpz t b*) \[Function\] int mpz*kronecker_si (\_const mpz t a, long b*) \[Function\] int mpz*kronecker_ui (\_const mpz t a, unsigned long b*) \[Function\] int mpz*si_kronecker (\_long a, const mpz t b*) \[Function\] int mpz*ui_kronecker (\_unsigned long a, const mpz t b*)\[Function\]

Calculate the Jacobi symbol ![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADcAAAA2CAYAAABjhwHjAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAAAP1SURBVGhD7Zq/bhNBEMY/6JEI11KgQIMo3IAUgYVEg1DEA7iDzvACriMhCl7AtNCFJ8BQgIQQCjgFVDQmSkEbG4kHOJr5ji+T+7u7jrHETzrdeHd9tzM7O/vvgP8U9HzCKZPZlZwxgKlPPGVGAGapjbwLYA5g02esgHFKBccAcgB9n7EiMvOgaAVHptjIZ6yYTfOkWWgf7Jti09AHLJmh1W/XZzSRmVXy2KY3MgAD84BhQmOxjgOfUcfTUKuUQNcemzcMrFJ984qYCEzvau2em/aH2FZjxy+zbE/eMXd5XWHrtYoLjI4xFgWAScNLmR/rHQMxUu1Qpa3mrd0FuuLMZwhs1aHP6Egmda4yJCCVytv6cAmZWTG3vluGVijG9Qm9rc6Yhf9OfEYH6CZ1Fd8WV0oBn5ebDAA4KwV6AC6b/E7Su3Jb5G8iK7fs/talh/JZ5PsiFzD811m8DQwUda1f1t9i3gl5ZuEN2nJ37b6osXgbfrm7JwNw3eQ9Sf8qcgiM7hucB1M5feEPu4fy3u7nXTp5IjKNuA3glaSH8EHkayIXI31ukScGRsuyyMU1Id9FJglWHarDLqTlbkqhGJcEgCMAdwBcsJfolOsQwA0Az63s0IafAwAf3XO68l1keiFglTgRSiPxk2U/e9i2vJjJgoc6zHWcZoSLjZSrRl2+R7e84gqtK0f6g8px8AaA3yKvM1s6zsHGuAOXtracsTvD8sKiXAiX7Irl0K4QxgAem/yIiRplQtmR58RcO/7BHdBVzTBlyz0E8MAnBvASwAuf2JIRgGcmJ225fwGu63IAQx9Q1p1jEwWv3IYvsM5QuYWknRN5ndmjcl9cxrpybN+HyunAfVXkFPRsZdBPOCmvgquBBYCfTDw2PvwtG41OyPOKNV4qdEdtBmm5T1Io5argns2C3tjvfZefEvW4fYhyutBbRrTkqoNbEMvgosgn3sM9y9QDeaqzhyZqd+9qMyPQvfxlwoVq0a91EH8t8pbIsXCTNtUGbBm6e1f5nhTb6R4+M2UU9pRup3vomo3HQS3R/ta3IWdqxpvb79ADF6XVQUiqIyyihyIT13o8tI89B9RTpUbvSHX4CHnWvCJI0VMaK1WDBqxGL0gZupuOdDkziunjfEfVWeAJUhz4q5Gq+m+bE9g6Oh/4w/lxaOu1Gd+40x2qHFutMkJWEfuRDftbXeuzcnVlquBHNsEHN3TPqj5TB1cEVcFCP9foGpk10oYYviD0wzYqV/U/Gq5Tf7Gy04RjMSZWiS79j/2pTDnt0137yzilYrDK8DvHtjCglLkcvaF1+DZGqRVTurQczH3U7WikKqWbyDq68FLJrHVm4trjZVne8wfj7Ve5kw+3QQAAAABJRU5ErkJggg==) with the Kronecker extension ![](data:image/png;base64,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) when _a_ odd, or ![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADcAAAA2CAYAAABjhwHjAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAAAP+SURBVGhD7ZqxaxRBFMY/7UXDlorItRbXaIRwCDYWh61ypd1Z2Yj3H6TwHwhYCVYRUlqcNjYSkLOxEJtERMXKbEDt1+Z9x3cvu3szO6PJiT9Y9mXmdnfezHtvZt4E+M+cgV3HRQFgZPesjAFUAPq+4i8zAzDNqeDIFBv6imOgALCXS0EqtukrjpE+gDJVwb4ptucrTgB0ky1fEQKH/yT4WRNTa9/IVyxjM6M59qynp3ZNxJxSou9ALKvnK5vgQ1WKTRtj849tacDYot6WfWPsnomB7wgeBA538AMN8MN1fjGRDow2K4EDUYZYgY5aiq/R4We+wtDvBJtUAzN7z7av8GwvaVQIPWl409zIKSZHJGZHlm0dpY2a+MoIaI6lrxDaTDaWIqTd7IEq0STLgIZzmknxN4VxotESaLuNPwiAE3/VEgXVQhrNKBINUAMAOC2VPQBXTH4p5bGcEfm9yMq63fcBfDS5HxLtWtgVeQNOOX4QAN6JHMs3kX+KrFy3u3biHQCX5e9YPoh8W2RAHHw+rAnQn+rewyhZOeePWmU0QLcqARQ6cldF1l7own27b7jyMYAHAF648pGNIk20Kwd2XwNwQSvYm23hO4aRvWvLRmjPVjyFXTOr30zduggaVObBTFcL08XfJ8PURF3jU4OIR5WbLx1VuaVLmBPMgh70uZQodVI5R+XOSuG+yKvMukZL8tkXrCqn7D4B8MjkewAey29ieOILOvIQwHdfGEAhzx2ysDaEdoDvSL0u+RdHwHeUuUfuri/oyA6AX74wkMru2UfuuNEdSVkXUFYZ3ZEs7ArIDV+wosxH7p8J/8JbKvfVVawqCzsBKqdbnJsirxoXRX5F5Q40dGamsAi87dLpOXcDROfHLyLPs0dVYuZLGdk+bsvkgeztKtvT5foWnA4Lu3qd65oSqTEMTYm6xnOzWtmGte43XWBK8Uj2bijKNSY2I1iWuy+kMSnZbaLpwtp8KT+WuhvnprFcYgWalEodPU08DVEziTPVtt6QFgiFiaE1ALdcnfJJ5PMid4HpQgB4gxrlntp9DcA1VxfDjm16DwE895UN/PAFkXAKeyZZsCOE5PlzwROlyke3SHTB3OYG86hZJprmMvRkJtXH6btLA5NGsVwnMHXwzL31TC2A6PZy9Jb2REcY2XLMcXrwGEQhq4hWG+4A/0GmaYKPQdvZNqcegZP6LKPvUbHc6fNOiWT6RY4VCxVL/Q8J0rP3BZujRw8soobdQcWaHL7LLoGL5CTTpoJ7HU2pb8+2NT52d0CLyhIPaAKxvkLF2hrOCTiUP/LvkYUpF5r64/lcFXCFTjmMjlkVi0WPkkKu1BVKLcw452ZQc2Tcxi6A174wld/SJF1XpGY1IQAAAABJRU5ErkJggg==)\= 0 when _a_ even.

When _b_ is odd the Jacobi symbol and Kronecker symbol are identical, so mpz_kronecker_ui etc can be used for mixed precision Jacobi symbols too.

For more information see Henri Cohen section 1.4.2 (see Appendix B \[References\], page 130), or any number theory textbook. See also the example program demos/qcn.c which uses mpz_kronecker_ui.

mp*bitcnt_t mpz_remove (\_mpz t rop, const mpz t op, const mpz t f*) \[Function\] Remove all occurrences of the factor _f_ from _op_ and store the result in _rop_. The return value is how many such occurrences were removed.

void mpz*fac_ui (\_mpz t rop, unsigned long int n*) \[Function\] void mpz*2fac_ui (\_mpz t rop, unsigned long int n*) \[Function\] void mpz*mfac_uiui (\_mpz t rop, unsigned long int n, unsigned long int m*) \[Function\] Set _rop_ to the factorial of _n_: mpz*fac_ui computes the plain factorial \_n*!, mpz*2fac_ui computes the double-factorial \_n*!!, and mpz*mfac_uiui the \_m*\-multi-factorial _n_!<sup>(</sup>_<sup>m</sup>_<sup>)</sup>.

void mpz*primorial_ui (\_mpz t rop, unsigned long int n*) \[Function\]

Set _rop_ to the primorial of _n_, i.e. the product of all positive prime numbers ≤ _n_.

void mpz*bin_ui (\_mpz t rop, const mpz t n, unsigned long int k*) \[Function\] void mpz*bin_uiui (\_mpz t rop, unsigned long int n, unsigned long int k*) \[Function\] Compute the binomial coefficient ![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADoAAAA2CAYAAACWeYpTAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAAAPOSURBVGhD7ZqxbhNBEIZ/6FFA7ilMhShOQkAQSY9kUSKUHqSIlsJvEAnxAOnowxuY1IAEFkgUKI1NEdGSgHgA08wf/Rl2725v1yE+5ZNOt96193ZmZ2Z9OwtcEGQEYOwr/xMVgF1fWYJtAEcm7HlgAGBqVzG2ACzsfp4YmPKLCEshu5jJpl0hBtI+8I0JVDa+LGEr09isw2Amppyp/b6y+qG1Tc3fd22gO+73KYxz+5h29MuxBK1NGwSFVaEJhc1xjZn1EbOgKNTSnm9owcxmDiKoCuvhsya+IYGR9XHkG+oYyo9SNbTp/GVbBI31VUJQ2HMX9sxW0JS6PLhyAu216Gti38ldoxk4F21iCmdz0cE3QxxZXzH/G7SY8RT4vMbAtCNm26iVBhj66zTMWUjyrRpojY39USNd1k0P/bNujaNpl3genHKjFsnIVWdqKVCImBmp2Wo03ss0Y05WNC7otHN5yKHJPznjM6nj37ocqOAFXeay+wIHNAfw3bWlUgG4ZuVPro2s2f2N1L0A8FI+d+GLlNfhBNWBzaW+K/ftXqe0D3a/ZpofW/mV+14q7BcAHkkZcAt76wW3hsp8JBoQjJGZ2qTQcwll+ScQ0j8XmYHgvMD4sIAz3btS/iPlVUXjQqWC3rH7MYCvUr+q/JLyTR91+4RG3jUK2gefrON6aEZja94qcyMkqNp2bwgJ2hf0T0OvBT3FhaA94IF+CAl61Vf0gZCg93xFD5hT0APX0DcOKehPqeQ76apzW8q/1XTfSjm0m57D2N43ecX2kEqiseZABdVdgCtSLsVnAA/tOvSNS4Cx5hjAD20ovcPgie34LYtTOww6o9+kvIyBrNv9LN539W1sH07QdzYIuN2GUmzYfd/VL4NbUn4v5RN03yiWQuhKcqYrA+7rRtMqmo1q2r1L4az9s3GnHoVzL6QpSctjPSVmO5h7Cf0FZIb7uavPIeaflZn0hr0/Piug4Cd2nwP46NpOUTo/ioh/blk9fUjTlTnQIltZR07G2xNK9G4FZo5Zb1+fguZaWyXJdFZzg4emImGChIQZFtiNpOUkHRHIOZWi0CRnNpBYCjEXKlTdoRUD0VCOptnHVM4CMaGUNKAGZmayneIKQ3XXABFaP3lyjMKXgNaXZLKenLOAsfVTFaCmPOgQEzgZJQLnibCp/kX/DPl5KO0fisZ18BjApKQbcNApPhBaP4k3abRMHBPGkKJCklHC7kDIPxUGJj0zmOKzlc1+cSFT4WFH75+E/rtr5diByCJc8hUFGQB4antRsRftIYDHVn7tNumK8hcIHjbyJGqycQAAAABJRU5ErkJggg==) and store the result in _rop_. Negative values of _n_ are supported by mpz_bin_ui, using the identity ![](data:image/png;base64,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), see Knuth volume 1 section 1.2.6 part G.

void mpz*fib_ui (\_mpz t fn, unsigned long int n*)

void mpz*fib2_ui (\_mpz t fn, mpz t fnsub1, unsigned long int n*) \[Function\] mpz*fib_ui sets \_fn* to _F<sub>n</sub>_, the _n_th Fibonacci number. mpz_fib2_ui sets \_fn_ to _F<sub>n</sub>_, and _fnsub1_ to *Fn*−1.

These functions are designed for calculating isolated Fibonacci numbers. When a sequence of values is wanted it's best to start with mpz*fib2_ui and iterate the defining \_F<sub>n</sub>*<sub>+1</sub> \= _F<sub>n</sub>_+_F<sub>n</sub>_<sub>−1</sub> or similar.

void mpz*lucnum_ui (\_mpz t ln, unsigned long int n*) \[Function\] void mpz*lucnum2_ui (\_mpz t ln, mpz t lnsub1, unsigned long int n*) \[Function\] mpz*lucnum_ui sets \_ln* to _L<sub>n</sub>_, the _n_th Lucas number. mpz_lucnum2_ui sets \_ln_ to _L<sub>n</sub>_, and _lnsub1_ to _L<sub>n</sub>_<sub>−1</sub>.

These functions are designed for calculating isolated Lucas numbers. When a sequence of values is wanted it's best to start with mpz*lucnum2_ui and iterate the defining \_L<sub>n</sub>*<sub>+1</sub> \= _L<sub>n</sub>_ \+ _L<sub>n</sub>_<sub>−1</sub> or similar.

The Fibonacci numbers and Lucas numbers are related sequences, so it's never necessary to call both mpz_fib2_ui and mpz_lucnum2_ui. The formulas for going from Fibonacci to Lucas can be found in Section 15.7.5 \[Lucas Numbers Algorithm\], page 115, the reverse is straightforward too.

## 5.10 Comparison Functions

int mpz*cmp (\_const mpz t op1, const mpz t op2*) \[Function\] int mpz*cmp_d (\_const mpz t op1, double op2*) \[Function\] int mpz*cmp_si (\_const mpz t op1, signed long int op2*) \[Macro\] int mpz*cmp_ui (\_const mpz t op1, unsigned long int op2*) \[Macro\]

Compare _op1_ and _op2_. Return a positive value if _op1 > op2_, zero if _op1_ \= _op2_, or a negative value if _op1 < op2_.

mpz_cmp_ui and mpz_cmp_si are macros and will evaluate their arguments more than once. mpz_cmp_d can be called with an infinity, but results are undefined for a NaN.

int mpz*cmpabs (\_const mpz t op1, const mpz t op2*) \[Function\] int mpz*cmpabs_d (\_const mpz t op1, double op2*) \[Function\] int mpz*cmpabs_ui (\_const mpz t op1, unsigned long int op2*) \[Function\]

Compare the absolute values of _op1_ and _op2_. Return a positive value if |_op1_| _\>_ |_op2_|, zero if |_op1_| = |_op2_|, or a negative value if |_op1_| _<_ |_op2_|. mpz_cmpabs_d can be called with an infinity, but results are undefined for a NaN.

int mpz*sgn (\_const mpz t op*) \[Macro\]

Return +1 if _op >_ 0, 0 if _op_ \= 0, and −1 if _op <_ 0.

This function is actually implemented as a macro. It evaluates its argument multiple times.

## 5.11 Logical and Bit Manipulation Functions

These functions behave as if two's complement arithmetic were used (although sign-magnitude is the actual implementation). The least significant bit is number 0.

void mpz*and (\_mpz t rop, const mpz t op1, const mpz t op2*) \[Function\]

Set _rop_ to _op1_ bitwise-and _op2_.

void mpz*ior (\_mpz t rop, const mpz t op1, const mpz t op2*) Set _rop_ to _op1_ bitwise inclusive-or _op2_.

void mpz*xor (\_mpz t rop, const mpz t op1, const mpz t op2*) \[Function\]

Set _rop_ to _op1_ bitwise exclusive-or _op2_.

void mpz*com (\_mpz t rop, const mpz t op*) \[Function\]

Set _rop_ to the one's complement of _op_.

mp*bitcnt_t mpz_popcount (\_const mpz t op*) \[Function\]

If _op_ ≥ 0, return the population count of _op_, which is the number of 1 bits in the binary representation. If _op <_ 0, the number of 1s is infinite, and the return value is the largest possible mp_bitcnt_t.

mp*bitcnt_t mpz_hamdist (\_const mpz t op1, const mpz t op2*) \[Function\] If _op1_ and _op2_ are both ≥ 0 or both _<_ 0, return the hamming distance between the two operands, which is the number of bit positions where _op1_ and _op2_ have different bit values. If one operand is ≥ 0 and the other _<_ 0 then the number of bits different is infinite, and the return value is the largest possible mp_bitcnt_t.

mp*bitcnt_t mpz_scan0 (\_const mpz t op, mp bitcnt t starting_bit*) \[Function\] mp*bitcnt_t mpz_scan1 (\_const mpz t op, mp bitcnt t starting_bit*) \[Function\]

Scan _op_, starting from bit _starting bit_, towards more significant bits, until the first 0 or 1 bit (respectively) is found. Return the index of the found bit.

If the bit at _starting bit_ is already what's sought, then _starting bit_ is returned.

If there's no bit found, then the largest possible mp_bitcnt_t is returned. This will happen in mpz_scan0 past the end of a negative number, or mpz_scan1 past the end of a nonnegative

| number.                                                                                    |              |
| ------------------------------------------------------------------------------------------ | ------------ |
| void mpz*setbit (\_mpz t rop, mp bitcnt t bit_index*) Set bit _bit index_ in _rop_.        | \[Function\] |
| void mpz*clrbit (\_mpz t rop, mp bitcnt t bit_index*) Clear bit _bit index_ in _rop_.      | \[Function\] |
| void mpz*combit (\_mpz t rop, mp bitcnt t bit_index*) Complement bit _bit index_ in _rop_. | \[Function\] |
| int mpz*tstbit (\_const mpz t op, mp bitcnt t bit_index*)                                  | \[Function\] |

Test bit _bit index_ in _op_ and return 0 or 1 accordingly.

Shifting is also possible using multiplication (Section 5.5 \[Integer Arithmetic\], page 34) and division (Section 5.6 \[Integer Division\], page 34), in particular the 2exp functions.

## 5.12 Input and Output Functions

Functions that perform input from a stdio stream, and functions that output to a stdio stream, of mpz numbers. Passing a NULL pointer for a _stream_ argument to any of these functions will make them read from stdin and write to stdout, respectively.

When using any of these functions, it is a good idea to include stdio.h before gmp.h, since that will allow gmp.h to define prototypes for these functions.

See also Chapter 10 \[Formatted Output\], page 74 and Chapter 11 \[Formatted Input\], page 79.

size*t mpz_out_str (\_FILE \*stream, int base, const mpz t op*) \[Function\]

Output _op_ on stdio stream _stream_, as a string of digits in base _base_. The base argument may vary from 2 to 62 or from −2 to −36.

For _base_ in the range 2..36, digits and lower-case letters are used; for −2..−36, digits and upper-case letters are used; for 37..62, digits, upper-case letters, and lower-case letters (in that significance order) are used.

Return the number of bytes written, or if an error occurred, return 0.

size*t mpz_inp_str (\_mpz t rop, FILE \*stream, int base*) \[Function\]

Input a possibly white-space preceded string in base _base_ from stdio stream _stream_, and put the read integer in _rop_.

The _base_ may vary from 2 to 62, or if _base_ is 0, then the leading characters are used: 0x and 0X for hexadecimal, 0b and 0B for binary, 0 for octal, or decimal otherwise.

For bases up to 36, case is ignored; upper-case and lower-case letters have the same value. For bases 37 to 62, upper-case letters represent the usual 10..35 while lower-case letters represent 36..61.

Return the number of bytes read, or if an error occurred, return 0.

size*t mpz_out_raw (\_FILE \*stream, const mpz t op*) \[Function\]

Output _op_ on stdio stream _stream_, in raw binary format. The integer is written in a portable format, with 4 bytes of size information, and that many bytes of limbs. Both the size and the limbs are written in decreasing significance order (i.e., in big-endian).

The output can be read with mpz_inp_raw.

Return the number of bytes written, or if an error occurred, return 0.

The output of this can not be read by mpz_inp_raw from GMP 1, because of changes necessary for compatibility between 32-bit and 64-bit machines.

size*t mpz_inp_raw (\_mpz t rop, FILE \*stream*) \[Function\]

Input from stdio stream _stream_ in the format written by mpz*out_raw, and put the result in \_rop*. Return the number of bytes read, or if an error occurred, return 0.

This routine can read the output from mpz_out_raw also from GMP 1, in spite of changes necessary for compatibility between 32-bit and 64-bit machines.

## 5.13 Random Number Functions

The random number functions of GMP come in two groups; older functions that rely on a global state, and newer functions that accept a state parameter that is read and modified. Please see the Chapter 9 \[Random Number Functions\], page 72 for more information on how to use and not to use random number functions.

void mpz*urandomb (\_mpz t rop, gmp randstate t state, mp bitcnt t n*) \[Function\] Generate a uniformly distributed random integer in the range 0 to 2sup*n* − 1, inclusive.

The variable _state_ must be initialized by calling one of the gmp_randinit functions (Section 9.1 \[Random State Initialization\], page 72) before invoking this function.

void mpz*urandomm (\_mpz t rop, gmp randstate t state, const mpz t n*) Generate a uniform random integer in the range 0 to _n_ − 1, inclusive.

The variable _state_ must be initialized by calling one of the gmp_randinit functions (Section 9.1 \[Random State Initialization\], page 72) before invoking this function.

void mpz*rrandomb (\_mpz t rop, gmp randstate t state, mp bitcnt t n*) \[Function\] Generate a random integer with long strings of zeros and ones in the binary representation. Useful for testing functions and algorithms, since this kind of random numbers have proven to be more likely to trigger corner-case bugs. The random number will be in the range 2sup*n*− 1 to 2sup*n* − 1, inclusive.

The variable _state_ must be initialized by calling one of the gmp_randinit functions (Section 9.1 \[Random State Initialization\], page 72) before invoking this function.

void mpz*random (\_mpz t rop, mp size t max_size*) \[Function\]

Generate a random integer of at most _max size_ limbs. The generated random number doesn't satisfy any particular requirements of randomness. Negative random numbers are generated when _max size_ is negative.

This function is obsolete. Use mpz_urandomb or mpz_urandomm instead.

void mpz*random2 (\_mpz t rop, mp size t max_size*) \[Function\]

Generate a random integer of at most _max size_ limbs, with long strings of zeros and ones in the binary representation. Useful for testing functions and algorithms, since this kind of random numbers have proven to be more likely to trigger corner-case bugs. Negative random numbers are generated when _max size_ is negative.

This function is obsolete. Use mpz_rrandomb instead.

## 5.14 Integer Import and Export

mpz_t variables can be converted to and from arbitrary words of binary data with the following functions.

void mpz*import (\_mpz t rop, size t count, int order, size t size, int* \[Function\] _endian, size t nails, const void \*op_) Set _rop_ from an array of word data at _op_.

The parameters specify the format of the data. _count_ many words are read, each _size_ bytes. _order_ can be 1 for most significant word first or -1 for least significant first. Within each word _endian_ can be 1 for most significant byte first, -1 for least significant first, or 0 for the native endianness of the host CPU. The most significant _nails_ bits of each word are skipped, this can be 0 to use the full words.

There is no sign taken from the data, _rop_ will simply be a positive integer. An application can handle any sign itself, and apply it for instance with mpz_neg.

There are no data alignment restrictions on _op_, any address is allowed.

Here's an example converting an array of unsignedlong data, most significant element first, and host byte order within each value.

unsigned long a\[20\]; /\* Initialize _z_ and _a_ \*/ mpz*import (z, 20, 1, sizeof(a\[0\]), 0, 0, a); This example assumes the full sizeof bytes are used for data in the given type, which is usually true, and certainly true for unsignedlong everywhere we know of. However on Cray vector systems it may be noted that short and int are always stored in 8 bytes (and with sizeof indicating that) but use only 32 or 46 bits. The \_nails* feature can account for this, by passing for instance 8\*sizeof(int)-INT_BIT.

void \* mpz*export (\_void \*rop, size t \*countp, int order, size t size, int* \[Function\] _endian, size t nails, const mpz t op_) Fill _rop_ with word data from _op_.

The parameters specify the format of the data produced. Each word will be _size_ bytes and _order_ can be 1 for most significant word first or -1 for least significant first. Within each word _endian_ can be 1 for most significant byte first, -1 for least significant first, or 0 for the native endianness of the host CPU. The most significant _nails_ bits of each word are unused and set to zero, this can be 0 to produce full words.

The number of words produced is written to \*_countp_, or _countp_ can be NULL to discard the count. _rop_ must have enough space for the data, or if _rop_ is NULL then a result array of the necessary size is allocated using the current GMP allocation function (see Chapter 13 \[Custom Allocation\], page 92). In either case the return value is the destination used, either _rop_ or the allocated block.

If _op_ is non-zero then the most significant word produced will be non-zero. If _op_ is zero then the count returned will be zero and nothing written to _rop_. If _rop_ is NULL in this case, no block is allocated, just NULL is returned.

The sign of _op_ is ignored, just the absolute value is exported. An application can use mpz*sgn to get the sign and handle it as desired. (see Section 5.10 \[Integer Comparisons\], page 40) There are no data alignment restrictions on \_rop*, any address is allowed.

When an application is allocating space itself the required size can be determined with a calculation like the following. Since mpz_sizeinbase always returns at least 1, count here will be at least one, which avoids any portability problems with malloc(0), though if z is zero no space at all is actually needed (or written).

numb = 8\*size - nail; count = (mpz_sizeinbase (z, 2) + numb-1) / numb; p = malloc (count \* size);

## 5.15 Miscellaneous Functions

int mpz*fits_ulong_p (\_const mpz t op*) \[Function\] int mpz*fits_slong_p (\_const mpz t op*) \[Function\] int mpz*fits_uint_p (\_const mpz t op*) \[Function\] int mpz*fits_sint_p (\_const mpz t op*) \[Function\] int mpz*fits_ushort_p (\_const mpz t op*) \[Function\] int mpz*fits_sshort_p (\_const mpz t op*) \[Function\]

Return non-zero iff the value of _op_ fits in an unsignedlongint, signedlongint, unsigned int, signedint, unsignedshortint, or signedshortint, respectively. Otherwise, return zero.

int mpz*odd_p (\_const mpz t op*) \[Macro\] int mpz*even_p (\_const mpz t op*) \[Macro\]

Determine whether _op_ is odd or even, respectively. Return non-zero if yes, zero if no. These macros evaluate their argument more than once.

size*t mpz_sizeinbase (\_const mpz t op, int base*) \[Function\]

Return the size of _op_ measured in number of digits in the given _base_. _base_ can vary from 2 to 62. The sign of _op_ is ignored, just the absolute value is used. The result will be either exact or 1 too big. If _base_ is a power of 2, the result is always exact. If _op_ is zero the return value is always 1.

This function can be used to determine the space required when converting _op_ to a string. The right amount of allocation is normally two more than the value returned by mpz_sizeinbase, one extra for a minus sign and one for the null-terminator.

It will be noted that mpz*sizeinbase(\_op*,2) can be used to locate the most significant 1 bit in _op_, counting from 1. (Unlike the bitwise functions which start from 0, See Section 5.11

\[Logical and Bit Manipulation Functions\], page 40.)

## 5.16 Special Functions

The functions in this section are for various special purposes. Most applications will not need them.

| void mpz*array_init (\_mpz t integer_array, mp size t array_size, mp size t fixed_num_bits*)<br><br>This is an obsolete function. Do not use it. | \[Function\] |
| ------------------------------------------------------------------------------------------------------------------------------------------------ | ------------ |
| void \* \_mpz*realloc (\_mpz t integer, mp size t new_alloc*)                                                                                    | \[Function\] |

Change the space for _integer_ to _new alloc_ limbs. The value in _integer_ is preserved if it fits, or is set to 0 if not. The return value is not useful to applications and should be ignored.

mpz_realloc2 is the preferred way to accomplish allocation changes like this. mpz_realloc2 and \_mpz_realloc are the same except that \_mpz_realloc takes its size in limbs.

mp*limb_t mpz_getlimbn (\_const mpz t op, mp size t n*) \[Function\]

Return limb number _n_ from _op_. The sign of _op_ is ignored, just the absolute value is used. The least significant limb is number 0.

mpz*size can be used to find how many limbs make up \_op*. mpz*getlimbn returns zero if \_n* is outside the range 0 to mpz*size(\_op*)-1.

size*t mpz_size (\_const mpz t op*) \[Function\]

Return the size of _op_ measured in number of limbs. If _op_ is zero, the returned value will be zero.

const mp*limb_t \* mpz_limbs_read (\_const mpz t x*) \[Function\]

Return a pointer to the limb array representing the absolute value of _x_. The size of the array is mpz*size(\_x*). Intended for read access only.

mp*limb_t \* mpz_limbs_write (\_mpz t x, mp size t n*) \[Function\] mp*limb_t \* mpz_limbs_modify (\_mpz t x, mp size t n*) \[Function\]

Return a pointer to the limb array, intended for write access. The array is reallocated as needed, to make room for _n_ limbs. Requires _n >_ 0\. The mpz*limbs_modify function returns an array that holds the old absolute value of \_x*, while mpz_limbs_write may destroy the old value and return an array with unspecified contents.

void mpz*limbs_finish (\_mpz t x, mp size t s*) \[Function\]

Updates the internal size field of _x_. Used after writing to the limb array pointer returned by mpz*limbs_write or mpz_limbs_modify is completed. The array should contain |\_s*| valid limbs, representing the new absolute value for _x_, and the sign of _x_ is taken from the sign of _s_. This function never reallocates _x_, so the limb pointer remains valid.

void foo (mpz_t x)

{ mp_size_t n, i; mp_limb_t \*xp;

n = mpz_size (x); xp = mpz_limbs_modify (x, 2\*n); for (i = 0; i < n; i++) xp\[n+i\] = xp\[n-1-i\];

mpz_limbs_finish (x, mpz_sgn (x) < 0 ? - 2\*n : 2\*n);

}

mpz*srcptr mpz_roinit_n (\_mpz t x, const mp limb t \*xp, mp size t xs*) \[Function\] Special initialization of _x_, using the given limb array and size. _x_ should be treated as readonly: it can be passed safely as input to any mpz function, but not as an output. The array _xp_ must point to at least a readable limb, its size is |_xs_|, and the sign of _x_ is the sign of _xs_.

For convenience, the function returns _x_, but cast to a const pointer type.

void foo (mpz_t x)

{ static const mp_limb_t y\[3\] = { 0x1, 0x2, 0x3 }; mpz_t tmp; mpz_add (x, x, mpz_roinit_n (tmp, y, 3));

}

mpz*t MPZ_ROINIT_N (\_mp limb t \*xp, mp size t xs*) \[Macro\]

This macro expands to an initializer which can be assigned to an mpz t variable. The limb array _xp_ must point to at least a readable limb, moreover, unlike the mpz*roinit_n function, the array must be normalized: if \_xs* is non-zero, then _xp_\[|_xs_|−1\] must be non-zero. Intended primarily for constant values. Using it for non-constant values requires a C compiler supporting C99.

void foo (mpz_t x)

{ static const mp_limb_t ya\[3\] = { 0x1, 0x2, 0x3 }; static const mpz_t y = MPZ_ROINIT_N ((mp_limb_t \*) ya, 3);

mpz_add (x, x, y);

}

# 6 Rational Number Functions

This chapter describes the GMP functions for performing arithmetic on rational numbers. These functions start with the prefix mpq\_.

Rational numbers are stored in objects of type mpq_t.

All rational arithmetic functions assume operands have a canonical form, and canonicalize their result. The canonical form means that the denominator and the numerator have no common factors, and that the denominator is positive. Zero has the unique representation 0/1.

Pure assignment functions do not canonicalize the assigned variable. It is the responsibility of the user to canonicalize the assigned variable before any arithmetic operations are performed on that variable.

void mpq*canonicalize (\_mpq t op*) \[Function\]

Remove any factors that are common to the numerator and denominator of _op_, and make the denominator positive.

## 6.1 Initialization and Assignment Functions

void mpq*init (\_mpq t x*) \[Function\]

Initialize _x_ and set it to 0/1. Each variable should normally only be initialized once, or at least cleared out (using the function mpq_clear) between each initialization.

void mpq*inits (\_mpq t x, ...*) \[Function\]

Initialize a NULL-terminated list of mpq_t variables, and set their values to 0/1.

void mpq*clear (\_mpq t x*) \[Function\]

Free the space occupied by _x_. Make sure to call this function for all mpq_t variables when you are done with them.

void mpq*clears (\_mpq t x, ...*) \[Function\]

Free the space occupied by a NULL-terminated list of mpq_t variables.

| void mpq*set (\_mpq t rop, const mpq t op*) void mpq*set_z (\_mpq t rop, const mpz t op*) | \[Function\]<br><br>\[Function\] |
| ----------------------------------------------------------------------------------------- | -------------------------------- |

Assign _rop_ from _op_.

void mpq*set_ui (\_mpqt rop, unsigned long int op1, unsigned long int op2*) \[Function\] void mpq*set_si (\_mpqt rop, signed long int op1, unsigned long int op2*) \[Function\] Set the value of _rop_ to _op1_/_op2_. Note that if _op1_ and _op2_ have common factors, _rop_ has to be passed to mpq*canonicalize before any operations are performed on \_rop*.

int mpq*set_str (\_mpq t rop, const char \*str, int base*) \[Function\]

Set _rop_ from a null-terminated string _str_ in the given _base_.

The string can be an integer like "41" or a fraction like "41/152". The fraction must be in canonical form (see Chapter 6 \[Rational Number Functions\], page 47), or if not then mpq_canonicalize must be called.

The numerator and optional denominator are parsed the same as in mpz*set_str (see Section 5.2 \[Assigning Integers\], page 32). White space is allowed in the string, and is simply ignored. The \_base* can vary from 2 to 62, or if _base_ is 0 then the leading characters are used: 0x or 0X for hex, 0b or 0B for binary, 0 for octal, or decimal otherwise. Note that this is done separately for the numerator and denominator, so for instance 0xEF/100 is 239/100, whereas 0xEF/0x100 is 239/256.

The return value is 0 if the entire string is a valid number, or −1 if not.

void mpq*swap (\_mpq t rop1, mpq t rop2*) \[Function\]

Swap the values _rop1_ and _rop2_ efficiently.

## 6.2 Conversion Functions

double mpq*get_d (\_const mpq t op*) \[Function\]

Convert _op_ to a double, truncating if necessary (i.e. rounding towards zero).

If the exponent from the conversion is too big or too small to fit a double then the result is system dependent. For too big an infinity is returned when available. For too small 0\_._0 is normally returned. Hardware overflow, underflow and denorm traps may or may not occur.

void mpq*set_d (\_mpqt rop, double op*) \[Function\] void mpq*set_f (\_mpqt rop, const mpf t op*) \[Function\]

Set _rop_ to the value of _op_. There is no rounding, this conversion is exact.

char \* mpq*get_str (\_char \*str, int base, const mpq t op*) \[Function\]

Convert _op_ to a string of digits in base _base_. The base argument may vary from 2 to 62 or from −2 to −36. The string will be of the form 'num/den', or if the denominator is 1 then just 'num'.

For _base_ in the range 2..36, digits and lower-case letters are used; for −2..−36, digits and upper-case letters are used; for 37..62, digits, upper-case letters, and lower-case letters (in that significance order) are used.

If _str_ is NULL, the result string is allocated using the current allocation function (see Chapter 13 \[Custom Allocation\], page 92). The block will be strlen(str)+1 bytes, that being exactly enough for the string and null-terminator.

If _str_ is not NULL, it should point to a block of storage large enough for the result, that being

mpz*sizeinbase (mpq_numref(\_op*), _base_)

\+ mpz*sizeinbase (mpq_denref(\_op*), _base_) + 3

The three extra bytes are for a possible minus sign, possible slash, and the null-terminator.

A pointer to the result string is returned, being either the allocated block, or the given _str_.

## 6.3 Arithmetic Functions

void mpq*add (\_mpq t sum, const mpq t addend1, const mpq t addend2*) \[Function\] Set _sum_ to _addend1_ \+ _addend2_.

void mpq*sub (\_mpq t difference, const mpq t minuend, const mpq t* \[Function\] _subtrahend_)

Set _difference_ to _minuend_ − _subtrahend_.

#### void mpq*mul (\_mpq t product, const mpq t multiplier, const mpq t* \[Function\] _multiplicand_)

Set _product_ to _multiplier_ × _multiplicand_.

| void mpq*mul_2exp (\_mpq t rop, const mpq t op1, mp bitcnt t op2*) Set _rop_ to _op1_ × 2*<sup>op</sup>*<sup>2</sup>.      | \[Function\] |
| -------------------------------------------------------------------------------------------------------------------------- | ------------ |
| void mpq*div (\_mpq t quotient, const mpq t dividend, const mpq t divisor*)<br><br>Set _quotient_ to _dividend_/_divisor_. | \[Function\] |
| void mpq*div_2exp (\_mpq t rop, const mpq t op1, mp bitcnt t op2*) Set _rop_ to _op1/\_2_<sup>op</sup>\_<sup>2</sup>.      | \[Function\] |
| void mpq*neg (\_mpq t negated_operand, const mpq t operand*) Set _negated operand_ to −*operand*.                          | \[Function\] |
| void mpq*abs (\_mpq t rop, const mpq t op*) Set _rop_ to the absolute value of _op_.                                       | \[Function\] |
| void mpq*inv (\_mpq t inverted_number, const mpq t number*)                                                                | \[Function\] |

Set _inverted number_ to 1/_number_. If the new denominator is zero, this routine will divide by zero.

## 6.4 Comparison Functions

int mpq*cmp (\_const mpq t op1, const mpq t op2*) \[Function\] int mpq*cmp_z (\_const mpq t op1, const mpz t op2*) \[Function\]

Compare _op1_ and _op2_. Return a positive value if _op1 > op2_, zero if _op1_ \= _op2_, and a negative value if _op1 < op2_.

To determine if two rationals are equal, mpq_equal is faster than mpq_cmp.

int mpq*cmp_ui (\_const mpqt op1, unsigned long int num2, unsigned long int* \[Macro\] _den2_)

int mpq*cmp_si (\_const mpqt op1, long int num2, unsigned long int den2*) \[Macro\] Compare _op1_ and _num2_/_den2_. Return a positive value if _op1 > num2/den2_, zero if _op1_ \= _num2/den2_, and a negative value if _op1 < num2/den2_. _num2_ and _den2_ are allowed to have common factors.

These functions are implemented as macros and evaluate their arguments multiple times.

int mpq*sgn (\_const mpq t op*) \[Macro\]

Return +1 if _op >_ 0, 0 if _op_ \= 0, and −1 if _op <_ 0.

This function is actually implemented as a macro. It evaluates its argument multiple times.

int mpq*equal (\_const mpq t op1, const mpq t op2*) \[Function\]

Return non-zero if _op1_ and _op2_ are equal, zero if they are non-equal. Although mpq_cmp can be used for the same purpose, this function is much faster.

## 6.5 Applying Integer Functions to Rationals

The set of mpq functions is quite small. In particular, there are few functions for either input or output. The following functions give direct access to the numerator and denominator of an mpq_t.

Note that if an assignment to the numerator and/or denominator could take an mpq_t out of the canonical form described at the start of this chapter (see Chapter 6 \[Rational Number Functions\], page 47) then mpq_canonicalize must be called before any other mpq functions are applied to that mpq_t.

mpz*ptr mpq_numref (\_const mpqt op*) \[Macro\] mpz*ptr mpq_denref (\_const mpqt op*) \[Macro\]

Return a reference to the numerator and denominator of _op_, respectively. The mpz functions can be used on the result of these macros. Such calls may modify the numerator or denominator. However, care should be taken so that _op_ remains in canonical form prior to a possible later call to an mpq function.

#### void mpq*get_num (\_mpzt numerator, const mpq t rational*) \[Function\] void mpq*get_den (\_mpzt denominator, const mpq t rational*) \[Function\] void mpq*set_num (\_mpqt rational, const mpz t numerator*) \[Function\] void mpq*set_den (\_mpqt rational, const mpz t denominator*) \[Function\]

Get or set the numerator or denominator of a rational. These functions are equivalent to calling mpz_set with an appropriate mpq_numref or mpq_denref. Direct use of mpq_numref or mpq_denref is recommended instead of these functions.

## 6.6 Input and Output Functions

Functions that perform input from a stdio stream, and functions that output to a stdio stream, of mpq numbers. Passing a NULL pointer for a _stream_ argument to any of these functions will make them read from stdin and write to stdout, respectively.

When using any of these functions, it is a good idea to include stdio.h before gmp.h, since that will allow gmp.h to define prototypes for these functions.

See also Chapter 10 \[Formatted Output\], page 74 and Chapter 11 \[Formatted Input\], page 79.

size*t mpq_out_str (\_FILE \*stream, int base, const mpq t op*) \[Function\]

Output _op_ on stdio stream _stream_, as a string of digits in base _base_. The base argument may vary from 2 to 62 or from −2 to −36. Output is in the form 'num/den' or if the denominator is 1 then just 'num'.

For _base_ in the range 2..36, digits and lower-case letters are used; for −2..−36, digits and upper-case letters are used; for 37..62, digits, upper-case letters, and lower-case letters (in that significance order) are used.

Return the number of bytes written, or if an error occurred, return 0.

size*t mpq_inp_str (\_mpq t rop, FILE \*stream, int base*) \[Function\]

Read a string of digits from _stream_ and convert them to a rational in _rop_. Any initial whitespace characters are read and discarded. Return the number of characters read (including white space), or 0 if a rational could not be read.

The input can be a fraction like '17/63' or just an integer like '123'. Reading stops at the first character not in this form, and white space is not permitted within the string. If the input might not be in canonical form, then mpq_canonicalize must be called (see Chapter 6 \[Rational Number Functions\], page 47).

The _base_ can be between 2 and 62, or can be 0 in which case the leading characters of the string determine the base, '0x' or '0X' for hexadecimal, 0b and 0B for binary, '0' for octal, or decimal otherwise. The leading characters are examined separately for the numerator and denominator of a fraction, so for instance '0x10/11' is 16*/\_11, whereas '0x10/0x11' is 16*/\_17.

# 7 Floating-point Functions

GMP floating point numbers are stored in objects of type mpf*t and functions operating on them have an mpf* prefix.

The mantissa of each float has a user-selectable precision, in practice only limited by available memory. Each variable has its own precision, and that can be increased or decreased at any time. This selectable precision is a minimum value, GMP rounds it up to a whole limb.

The accuracy of a calculation is determined by the priorly set precision of the destination variable and the numeric values of the input variables. Input variables' set precisions do not affect calculations (except indirectly as their values might have been affected when they were assigned).

The exponent of each float has fixed precision, one machine word on most systems. In the current implementation the exponent is a count of limbs, so for example on a 32-bit system this means a range of roughly 2<sup>−68719476768</sup> to 2<sup>68719476736</sup>, or on a 64-bit system this will be much greater. Note however that mpf_get_str can only return an exponent which fits an mp_exp_t and currently mpf_set_str doesn't accept exponents bigger than a long.

Each variable keeps track of the mantissa data actually in use. This means that if a float is exactly represented in only a few bits then only those bits will be used in a calculation, even if the variable's selected precision is high. This is a performance optimization; it does not affect the numeric results.

Internally, GMP sometimes calculates with higher precision than that of the destination variable in order to limit errors. Final results are always truncated to the destination variable's precision.

The mantissa is stored in binary. One consequence of this is that decimal fractions like 0\_._1 cannot be represented exactly. The same is true of plain IEEE double floats. This makes both highly unsuitable for calculations involving money or other values that should be exact decimal fractions. (Suitably scaled integers, or perhaps rationals, are better choices.)

The mpf functions and variables have no special notion of infinity or not-a-number, and applications must take care not to overflow the exponent or results will be unpredictable.

Note that the mpf functions are _not_ intended as a smooth extension to IEEE P754 arithmetic. In particular results obtained on one computer often differ from the results on a computer with a different word size.

New projects should consider using the GMP extension library MPFR (<https://www.mpfr.org/> ) instead. MPFR provides well-defined precision and accurate rounding, and thereby naturally extends IEEE P754.

## 7.1 Initialization Functions

void mpf*set_default_prec (\_mp bitcnt t prec*) \[Function\]

Set the default precision to be at least _prec_ bits. All subsequent calls to mpf_init will use this precision, but previously initialized variables are unaffected.

mp*bitcnt_t mpf_get_default_prec (\_void*) \[Function\]

Return the default precision actually used.

An mpf_t object must be initialized before storing the first value in it. The functions mpf_init and mpf_init2 are used for that purpose.

void mpf*init (\_mpf t x*) \[Function\]

Initialize _x_ to 0. Normally, a variable should be initialized once only or at least be cleared, using mpf*clear, between initializations. The precision of \_x* is undefined unless a default precision has already been established by a call to mpf_set_default_prec.

void mpf*init2 (\_mpf t x, mp bitcnt t prec*) \[Function\]

Initialize _x_ to 0 and set its precision to be at least _prec_ bits. Normally, a variable should be initialized once only or at least be cleared, using mpf_clear, between initializations.

void mpf*inits (\_mpf t x, ...*) \[Function\]

Initialize a NULL-terminated list of mpf_t variables, and set their values to 0. The precision of the initialized variables is undefined unless a default precision has already been established by a call to mpf_set_default_prec.

void mpf*clear (\_mpf t x*) \[Function\]

Free the space occupied by _x_. Make sure to call this function for all mpf_t variables when you are done with them.

void mpf*clears (\_mpf t x, ...*) \[Function\]

Free the space occupied by a NULL-terminated list of mpf_t variables.

Here is an example on how to initialize floating-point variables:

{ mpf*t x, y; mpf_init (x); /\* use default precision \*/ mpf_init2 (y, 256); /\* precision \_at least* 256 bits \*/

...

/\* Unless the program is about to exit, do ... \*/ mpf_clear (x); mpf_clear (y);

}

The following three functions are useful for changing the precision during a calculation. A typical use would be for adjusting the precision gradually in iterative algorithms like Newton-Raphson, making the computation precision closely match the actual accurate part of the numbers.

mp*bitcnt_t mpf_get_prec (\_const mpf t op*) \[Function\]

Return the current precision of _op_, in bits.

void mpf*set_prec (\_mpf t rop, mp bitcnt t prec*) \[Function\]

Set the precision of _rop_ to be at least _prec_ bits. The value in _rop_ will be truncated to the new precision.

This function requires a call to realloc, and so should not be used in a tight loop.

void mpf*set_prec_raw (\_mpf t rop, mp bitcnt t prec*) \[Function\]

Set the precision of _rop_ to be at least _prec_ bits, without changing the memory allocated.

_prec_ must be no more than the allocated precision for _rop_, that being the precision when _rop_ was initialized, or in the most recent mpf_set_prec.

The value in _rop_ is unchanged, and in particular if it had a higher precision than _prec_ it will retain that higher precision. New values written to _rop_ will use the new _prec_.

Before calling mpf*clear or the full mpf_set_prec, another mpf_set_prec_raw call must be made to restore \_rop* to its original allocated precision. Failing to do so will have unpredictable results.

mpf*get_prec can be used before mpf_set_prec_raw to get the original allocated precision. After mpf_set_prec_raw it reflects the \_prec* value set.

mpf_set_prec_raw is an efficient way to use an mpf_t variable at different precisions during a calculation, perhaps to gradually increase precision in an iteration, or just to use various different precisions for different purposes during a calculation.

## 7.2 Assignment Functions

These functions assign new values to already initialized floats (see Section 7.1 \[Initializing Floats\], page 52).

void mpf*set (\_mpf t rop, const mpf t op*) \[Function\] void mpf*set_ui (\_mpf t rop, unsigned long int op*) \[Function\] void mpf*set_si (\_mpf t rop, signed long int op*) \[Function\] void mpf*set_d (\_mpf t rop, double op*) \[Function\] void mpf*set_z (\_mpf t rop, const mpzt op*) \[Function\] void mpf*set_q (\_mpf t rop, const mpqt op*) \[Function\]

| Set the value of _rop_ from _op_.                          |              |
| ---------------------------------------------------------- | ------------ |
| int mpf*set_str (\_mpf t rop, const char \*str, int base*) | \[Function\] |

Set the value of _rop_ from the string in _str_. The string is of the form 'M@N' or, if the base is 10 or less, alternatively 'MeN'. 'M' is the mantissa and 'N' is the exponent. The mantissa is always in the specified base. The exponent is either in the specified base or, if _base_ is negative, in decimal. The decimal point expected is taken from the current locale, on systems providing localeconv.

The argument _base_ may be in the ranges 2 to 62, or −62 to −2. Negative values are used to specify that the exponent is in decimal.

For bases up to 36, case is ignored; upper-case and lower-case letters have the same value; for bases 37 to 62, upper-case letters represent the usual 10..35 while lower-case letters represent 36..61.

Unlike the corresponding mpz function, the base will not be determined from the leading characters of the string if _base_ is 0. This is so that numbers like '0.23' are not interpreted as octal.

White space is allowed in the string, and is simply ignored. \[This is not really true; whitespace is ignored in the beginning of the string and within the mantissa, but not in other places, such as after a minus sign or in the exponent. We are considering changing the definition of this function, making it fail when there is any white-space in the input, since that makes a lot of sense. Please tell us your opinion about this change. Do you really want it to accept "314" as meaning 314 as it does now?\]

This function returns 0 if the entire string is a valid number in base _base_. Otherwise it returns −1.

void mpf*swap (\_mpf t rop1, mpf t rop2*) \[Function\]

Swap _rop1_ and _rop2_ efficiently. Both the values and the precisions of the two variables are swapped.

## 7.3 Combined Initialization and Assignment Functions

For convenience, GMP provides a parallel series of initialize-and-set functions which initialize the output and then store the value there. These functions' names have the form mpf_init_set...

Once the float has been initialized by any of the mpf_init_set... functions, it can be used as the source or destination operand for the ordinary float functions. Don't use an initialize-and-set function on a variable already initialized!

void mpf*init_set (\_mpf t rop, const mpf t op*) \[Function\] void mpf*init_set_ui (\_mpf t rop, unsigned long int op*) \[Function\] void mpf*init_set_si (\_mpf t rop, signed long int op*) \[Function\] void mpf*init_set_d (\_mpf t rop, double op*) \[Function\]

Initialize _rop_ and set its value from _op_.

The precision of _rop_ will be taken from the active default precision, as set by mpf*set* default_prec.

int mpf*init_set_str (\_mpf t rop, const char \*str, int base*) \[Function\]

Initialize _rop_ and set its value from the string in _str_. See mpf_set_str above for details on the assignment operation.

Note that _rop_ is initialized even if an error occurs. (I.e., you have to call mpf_clear for it.)

The precision of _rop_ will be taken from the active default precision, as set by mpf*set* default_prec.

## 7.4 Conversion Functions

double mpf*get_d (\_const mpf t op*) \[Function\]

Convert _op_ to a double, truncating if necessary (i.e. rounding towards zero).

If the exponent in _op_ is too big or too small to fit a double then the result is system dependent. For too big an infinity is returned when available. For too small 0\_._0 is normally returned. Hardware overflow, underflow and denorm traps may or may not occur.

double mpf*get_d_2exp (\_signed long int \*exp, const mpf t op*) \[Function\]

Convert _op_ to a double, truncating if necessary (i.e. rounding towards zero), and with an exponent returned separately.

The return value is in the range 0*.\_5 ≤ |\_d*| _<_ 1 and the exponent is stored to \*_exp_. _d_ × 2*<sup>exp</sup>* is the (truncated) _op_ value. If _op_ is zero, the return is 0*.\_0 and 0 is stored to \*\_exp*.

This is similar to the standard C frexp function (see Section "Normalization Functions" in _The GNU C Library Reference Manual_).

long mpf*get_si (\_const mpf t op*) \[Function\] unsigned long mpf*get_ui (\_const mpf t op*) \[Function\]

Convert _op_ to a long or unsignedlong, truncating any fraction part. If _op_ is too big for the return type, the result is undefined.

See also mpf_fits_slong_p and mpf_fits_ulong_p (see Section 7.8 \[Miscellaneous Float Functions\], page 58).

char \* mpf*get_str (\_char \*str, mp exp t \*expptr, int base, size t n_digits, const mpf t op*)

Convert _op_ to a string of digits in base _base_. The base argument may vary from 2 to 62 or from −2 to −36. Up to _n digits_ digits will be generated. Trailing zeros are not returned. No more digits than can be accurately represented by _op_ are ever generated. If _n digits_ is 0 then that accurate maximum number of digits are generated.

For _base_ in the range 2..36, digits and lower-case letters are used; for −2..−36, digits and upper-case letters are used; for 37..62, digits, upper-case letters, and lower-case letters (in that significance order) are used.

If _str_ is NULL, the result string is allocated using the current allocation function (see Chapter 13 \[Custom Allocation\], page 92). The block will be strlen(str)+1 bytes, that being exactly enough for the string and null-terminator.

If _str_ is not NULL, it should point to a block of _n digits_ \+ 2 bytes, that being enough for the mantissa, a possible minus sign, and a null-terminator. When _n digits_ is 0 to get all significant digits, an application won't be able to know the space required, and _str_ should be NULL in that case.

The generated string is a fraction, with an implicit radix point immediately to the left of the first digit. The applicable exponent is written through the _expptr_ pointer. For example, the number 3.1416 would be returned as string "31416" and exponent 1.

When _op_ is zero, an empty string is produced and the exponent returned is 0.

A pointer to the result string is returned, being either the allocated block or the given _str_.

## 7.5 Arithmetic Functions

| void mpf*add (\_mpf t rop, const mpf t op1, const mpf t op2*) void mpf*add_ui (\_mpf t rop, const mpf t op1, unsigned long int op2*) Set _rop_ to _op1_ \+ _op2_. | \[Function\]<br><br>\[Function\] |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| void mpf*sub (\_mpf t rop, const mpf t op1, const mpf t op2*)                                                                                                     | \[Function\]                     |

void mpf*ui_sub (\_mpf t rop, unsigned long int op1, const mpf t op2*) \[Function\] void mpf*sub_ui (\_mpf t rop, const mpf t op1, unsigned long int op2*) \[Function\]

| Set _rop_ to _op1_ − _op2_.                                                                                                                                      |                                  |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| void mpf*mul (\_mpf t rop, const mpf t op1, const mpf t op2*) void mpf*mul_ui (\_mpf t rop, const mpf t op1, unsigned long int op2*) Set _rop_ to _op1_ × _op2_. | \[Function\]<br><br>\[Function\] |

Division is undefined if the divisor is zero, and passing a zero divisor to the divide functions will make these functions intentionally divide by zero. This lets the user handle arithmetic exceptions in these functions in the same manner as other arithmetic exceptions.

void mpf*div (\_mpf t rop, const mpf t op1, const mpf t op2*) \[Function\] void mpf*ui_div (\_mpf t rop, unsigned long int op1, const mpf t op2*) \[Function\] void mpf*div_ui (\_mpf t rop, const mpf t op1, unsigned long int op2*) \[Function\] Set _rop_ to _op1_/_op2_.

void mpf*sqrt (\_mpf t rop, const mpf t op*) \[Function\] void mpf*sqrt_ui (\_mpf t rop, unsigned long int op*) \[Function\] √ Set _rop_ to _op_.

void mpf*pow_ui (\_mpf t rop, const mpf t op1, unsigned long int op2*) Set _rop_ to _op1<sup>op</sup>_<sup>2</sup>.

| void mpf*neg (\_mpf t rop, const mpf t op*) Set _rop_ to −*op*.                                                                                           | \[Function\] |
| --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| void mpf*abs (\_mpf t rop, const mpf t op*) Set _rop_ to the absolute value of _op_.                                                                      | \[Function\] |
| void mpf*mul_2exp (\_mpf t rop, const mpf t op1, mp bitcnt t op2*) Set _rop_ to _op1_ × 2*<sup>op</sup>*<sup>2</sup>.                                     | \[Function\] |
| void mpf*div_2exp (\_mpf t rop, const mpf t op1, mp bitcnt t op2*) Set _rop_ to _op1/\_2_<sup>op</sup>\_<sup>2</sup>.<br><br>**7.6 Comparison Functions** | \[Function\] |
| int mpf*cmp (\_const mpf t op1, const mpf t op2*)                                                                                                         | \[Function\] |

int mpf*cmp_z (\_const mpf t op1, const mpz t op2*) \[Function\] int mpf*cmp_d (\_const mpf t op1, double op2*) \[Function\] int mpf*cmp_ui (\_const mpf t op1, unsigned long int op2*) \[Function\] int mpf*cmp_si (\_const mpf t op1, signed long int op2*) \[Function\]

Compare _op1_ and _op2_. Return a positive value if _op1 > op2_, zero if _op1_ \= _op2_, and a negative value if _op1 < op2_. mpf_cmp_d can be called with an infinity, but results are undefined for a NaN.

int mpf*eq (\_const mpf t op1, const mpf t op2, mp bitcnt t op3*) \[Function\]

This function is mathematically ill-defined and should not be used.

Return non-zero if the first _op3_ bits of _op1_ and _op2_ are equal, zero otherwise. Note that numbers like e.g., 256 (binary 100000000) and 255 (binary 11111111) will never be equal by this function's measure, and furthermore that 0 will only be equal to itself.

void mpf*reldiff (\_mpf t rop, const mpf t op1, const mpf t op2*) \[Function\]

Compute the relative difference between _op1_ and _op2_ and store the result in _rop_. This is |_op1_ − _op2_|_/op1_.

int mpf*sgn (\_const mpf t op*) \[Macro\]

Return +1 if _op >_ 0, 0 if _op_ \= 0, and −1 if _op <_ 0.

This function is actually implemented as a macro. It evaluates its argument multiple times.

## 7.7 Input and Output Functions

Functions that perform input from a stdio stream, and functions that output to a stdio stream, of mpf numbers. Passing a NULL pointer for a _stream_ argument to any of these functions will make them read from stdin and write to stdout, respectively.

When using any of these functions, it is a good idea to include stdio.h before gmp.h, since that will allow gmp.h to define prototypes for these functions.

See also Chapter 10 \[Formatted Output\], page 74 and Chapter 11 \[Formatted Input\], page 79.

size*t mpf_out_str (\_FILE \*stream, int base, size t n_digits, const mpf t op*)

Print _op_ to _stream_, as a string of digits. Return the number of bytes written, or if an error occurred, return 0.

The mantissa is prefixed with an '0.' and is in the given _base_, which may vary from 2 to 62 or from −2 to −36. An exponent is then printed, separated by an 'e', or if the base is greater than 10 then by an '@'. The exponent is always in decimal. The decimal point follows the current locale, on systems providing localeconv.

For _base_ in the range 2..36, digits and lower-case letters are used; for −2..−36, digits and upper-case letters are used; for 37..62, digits, upper-case letters, and lower-case letters (in that significance order) are used.

Up to _n digits_ will be printed from the mantissa, except that no more digits than are accurately representable by _op_ will be printed. _n digits_ can be 0 to select that accurate maximum.

size*t mpf_inp_str (\_mpf t rop, FILE \*stream, int base*) \[Function\]

Read a string in base _base_ from _stream_, and put the read float in _rop_. The string is of the form 'M@N' or, if the base is 10 or less, alternatively 'MeN'. 'M' is the mantissa and 'N' is the exponent. The mantissa is always in the specified base. The exponent is either in the specified base or, if _base_ is negative, in decimal. The decimal point expected is taken from the current locale, on systems providing localeconv.

The argument _base_ may be in the ranges 2 to 36, or −36 to −2. Negative values are used to specify that the exponent is in decimal.

Unlike the corresponding mpz function, the base will not be determined from the leading characters of the string if _base_ is 0. This is so that numbers like '0.23' are not interpreted as octal.

Return the number of bytes read, or if an error occurred, return 0.

## 7.8 Miscellaneous Functions

void mpf*ceil (\_mpf t rop, const mpf t op*) \[Function\] void mpf*floor (\_mpf t rop, const mpf t op*) \[Function\] void mpf*trunc (\_mpf t rop, const mpf t op*) \[Function\]

Set _rop_ to _op_ rounded to an integer. mpf_ceil rounds to the next higher integer, mpf_floor to the next lower, and mpf_trunc to the integer towards zero.

| int mpf*integer_p (\_const mpf t op*) Return non-zero if _op_ is an integer. | \[Function\] |
| ---------------------------------------------------------------------------- | ------------ |
| int mpf*fits_ulong_p (\_const mpf t op*)                                     | \[Function\] |

int mpf*fits_slong_p (\_const mpf t op*) \[Function\] int mpf*fits_uint_p (\_const mpf t op*) \[Function\] int mpf*fits_sint_p (\_const mpf t op*) \[Function\] int mpf*fits_ushort_p (\_const mpf t op*) \[Function\] int mpf*fits_sshort_p (\_const mpf t op*) \[Function\]

Return non-zero if _op_ would fit in the respective C data type, when truncated to an integer.

void mpf*urandomb (\_mpf t rop, gmp randstate t state, mp bitcnt t* \[Function\]

#### _nbits_)

Generate a uniformly distributed random float in _rop_, such that 0 ≤ _rop <_ 1, with _nbits_ significant bits in the mantissa or less if the precision of _rop_ is smaller.

The variable _state_ must be initialized by calling one of the gmp_randinit functions (Section 9.1 \[Random State Initialization\], page 72) before invoking this function.

void mpf*random2 (\_mpf t rop, mp size t max_size, mp exp t exp*) \[Function\] Generate a random float of at most _max size_ limbs, with long strings of zeros and ones in the binary representation. The exponent of the number is in the interval −*exp* to _exp_ (in limbs). This function is useful for testing functions and algorithms, since these kind of random numbers have proven to be more likely to trigger corner-case bugs. Negative random numbers are generated when _max size_ is negative.

# 8 Low-level Functions

This chapter describes low-level GMP functions, used to implement the high-level GMP functions, but also intended for time-critical user code.

These functions start with the prefix mpn\_.

The mpn functions are designed to be as fast as possible, not to provide a coherent calling interface. The different functions have somewhat similar interfaces, but there are variations that make them hard to use. These functions do as little as possible apart from the real multiple precision computation, so that no time is spent on things that not all callers need.

A source operand is specified by a pointer to the least significant limb and a limb count. A destination operand is specified by just a pointer. It is the responsibility of the caller to ensure that the destination has enough space for storing the result.

With this way of specifying operands, it is possible to perform computations on subranges of an argument, and store the result into a subrange of a destination.

A common requirement for all functions is that each source area needs at least one limb. No size argument may be zero. Unless otherwise stated, in-place operations are allowed where source and destination are the same, but not where they only partly overlap.

The mpn functions are the base for the implementation of the mpz*, mpf*, and mpq\_ functions.

This example adds the number beginning at _s1p_ and the number beginning at _s2p_ and writes the sum at _destp_. All areas have _n_ limbs.

cy = mpn_add_n (destp, s1p, s2p, n)

It should be noted that the mpn functions make no attempt to identify high or low zero limbs on their operands, or other special forms. On random data such cases will be unlikely and it'd be wasteful for every function to check every time. An application knowing something about its data can take steps to trim or perhaps split its calculations.

In the notation used below, a source operand is identified by the pointer to the least significant limb, and the limb count in braces. For example, {_s1p_, _s1n_}.

mp*limb_t mpn_add_n (\_mp limb t \*rp, const mp limb t \*s1p, const* \[Function\] _mp limb t \*s2p, mp size t n_)

Add {_s1p_, _n_} and {_s2p_, _n_}, and write the _n_ least significant limbs of the result to _rp_. Return carry, either 0 or 1.

This is the lowest-level function for addition. It is the preferred function for addition, since it is written in assembly for most CPUs. For addition of a variable to itself (i.e., _s1p_ equals _s2p_) use mpn_lshift with a count of 1 for optimal speed.

mp*limb_t mpn_add_1 (\_mp limb t \*rp, const mp limb t \*s1p, mp size t n,* \[Function\] _mp limb t s2limb_)

Add {_s1p_, _n_} and _s2limb_, and write the _n_ least significant limbs of the result to _rp_. Return carry, either 0 or 1.

mp*limb_t mpn_add (\_mp limb t \*rp, const mp limb t \*s1p, mp size t s1n,* \[Function\] _const mp limb t \*s2p, mp size t s2n_)

Add {_s1p_, _s1n_} and {_s2p_, _s2n_}, and write the _s1n_ least significant limbs of the result to _rp_. Return carry, either 0 or 1.

This function requires that _s1n_ is greater than or equal to _s2n_.

mp*limb_t mpn_sub_n (\_mp limb t \*rp, const mp limb t \*s1p, const* \[Function\] _mp limb t \*s2p, mp size t n_)

Subtract {_s2p_, _n_} from {_s1p_, _n_}, and write the _n_ least significant limbs of the result to _rp_. Return borrow, either 0 or 1.

This is the lowest-level function for subtraction. It is the preferred function for subtraction, since it is written in assembly for most CPUs.

mp*limb_t mpn_sub_1 (\_mp limb t \*rp, const mp limb t \*s1p, mp size t n,* \[Function\] _mp limb t s2limb_)

Subtract _s2limb_ from {_s1p_, _n_}, and write the _n_ least significant limbs of the result to _rp_. Return borrow, either 0 or 1.

mp*limb_t mpn_sub (\_mp limb t \*rp, const mp limb t \*s1p, mp size t s1n,* \[Function\] _const mp limb t \*s2p, mp size t s2n_)

Subtract {_s2p_, _s2n_} from {_s1p_, _s1n_}, and write the _s1n_ least significant limbs of the result to _rp_. Return borrow, either 0 or 1.

This function requires that _s1n_ is greater than or equal to _s2n_.

mp*limb_t mpn_neg (\_mp limb t \*rp, const mp limb t \*sp, mp size t n*) \[Function\]

Perform the negation of {_sp_, _n_}, and write the result to {_rp_, _n_}. This is equivalent to calling mpn*sub_n with an \_n*\-limb zero minuend and passing {_sp_, _n_} as subtrahend. Return borrow, either 0 or 1.

void mpn*mul_n (\_mp limb t \*rp, const mp limb t \*s1p, const mp limb t* \[Function\] _\*s2p, mp size t n_)

Multiply {_s1p_, _n_} and {_s2p_, _n_}, and write the 2\*_n_\-limb result to _rp_.

The destination has to have space for 2\*_n_ limbs, even if the product's most significant limb is zero. No overlap is permitted between the destination and either source.

If the two input operands are the same, use mpn_sqr.

mp*limb_t mpn_mul (\_mp limb t \*rp, const mp limb t \*s1p, mp size t s1n,* \[Function\] _const mp limb t \*s2p, mp size t s2n_)

Multiply {_s1p_, _s1n_} and {_s2p_, _s2n_}, and write the (_s1n_+_s2n_)-limb result to _rp_. Return the most significant limb of the result.

The destination has to have space for _s1n_ \+ _s2n_ limbs, even if the product's most significant limb is zero. No overlap is permitted between the destination and either source.

This function requires that _s1n_ is greater than or equal to _s2n_.

void mpn*sqr (\_mp limb t \*rp, const mp limb t \*s1p, mp size t n*) \[Function\]

Compute the square of {_s1p_, _n_} and write the 2\*_n_\-limb result to _rp_.

The destination has to have space for 2*n* limbs, even if the result's most significant limb is zero. No overlap is permitted between the destination and the source.

mp*limb_t mpn_mul_1 (\_mp limb t \*rp, const mp limb t \*s1p, mp size t n,* \[Function\] _mp limb t s2limb_)

Multiply {_s1p_, _n_} by _s2limb_, and write the _n_ least significant limbs of the product to _rp_. Return the most significant limb of the product. {_s1p_, _n_} and {_rp_, _n_} are allowed to overlap provided _rp_ ≤ _s1p_.

This is a low-level function that is a building block for general multiplication as well as other operations in GMP. It is written in assembly for most CPUs.

Don't call this function if _s2limb_ is a power of 2; use mpn*lshift with a count equal to the logarithm of \_s2limb* instead, for optimal speed.

mp*limb_t mpn_addmul_1 (\_mp limb t \*rp, const mp limb t \*s1p, mp size t* \[Function\] _n, mp limb t s2limb_)

Multiply {_s1p_, _n_} and _s2limb_, and add the _n_ least significant limbs of the product to {_rp_, _n_} and write the result to _rp_. Return the most significant limb of the product, plus carry-out from the addition. {_s1p_, _n_} and {_rp_, _n_} are allowed to overlap provided _rp_ ≤ _s1p_.

This is a low-level function that is a building block for general multiplication as well as other operations in GMP. It is written in assembly for most CPUs.

mp*limb_t mpn_submul_1 (\_mp limb t \*rp, const mp limb t \*s1p, mp size t* \[Function\] _n, mp limb t s2limb_)

Multiply {_s1p_, _n_} and _s2limb_, and subtract the _n_ least significant limbs of the product from {_rp_, _n_} and write the result to _rp_. Return the most significant limb of the product, plus borrow-out from the subtraction. {_s1p_, _n_} and {_rp_, _n_} are allowed to overlap provided _rp_ ≤ _s1p_.

This is a low-level function that is a building block for general multiplication and division as well as other operations in GMP. It is written in assembly for most CPUs.

void mpn*tdiv_qr (\_mp limb t \*qp, mp limb t \*rp, mp size t qxn, const* \[Function\] _mp limb t \*np, mp size t nn, const mp limb t \*dp, mp size t dn_)

Divide {_np_, _nn_} by {_dp_, _dn_} and put the quotient at {_qp_, *nn*−*dn*+1} and the remainder at {_rp_, _dn_}. The quotient is rounded towards 0.

No overlap is permitted between arguments, except that _np_ might equal _rp_. The dividend size _nn_ must be greater than or equal to divisor size _dn_. The most significant limb of the divisor must be non-zero. The _qxn_ operand must be zero.

mp*limb_t mpn_divrem (\_mp limb t \*r1p, mp size t qxn, mp limb t \*rs2p,* \[Function\] _mp size t rs2n, const mp limb t \*s3p, mp size t s3n_)

\[This function is obsolete. Please call mpn_tdiv_qr instead for best performance.\]

Divide {_rs2p_, _rs2n_} by {_s3p_, _s3n_}, and write the quotient at _r1p_, with the exception of the most significant limb, which is returned. The remainder replaces the dividend at _rs2p_; it will be _s3n_ limbs long (i.e., as many limbs as the divisor).

In addition to an integer quotient, _qxn_ fraction limbs are developed, and stored after the integral limbs. For most usages, _qxn_ will be zero.

It is required that _rs2n_ is greater than or equal to _s3n_. It is required that the most significant bit of the divisor is set.

If the quotient is not needed, pass _rs2p_ \+ _s3n_ as _r1p_. Aside from that special case, no overlap between arguments is permitted.

Return the most significant limb of the quotient, either 0 or 1.

The area at _r1p_ needs to be _rs2n_ − _s3n_ \+ _qxn_ limbs large.

mp*limb_t mpn_divrem_1 (\_mp limb t \*r1p, mp size t qxn, mp limb t \*s2p,* \[Function\] _mp size t s2n, mp limb t s3limb_)

mp*limb_t mpn_divmod_1 (\_mp limb t \*r1p, mp limb t \*s2p, mp size t s2n,* \[Macro\] _mp limb t s3limb_)

Divide {_s2p_, _s2n_} by _s3limb_, and write the quotient at _r1p_. Return the remainder.

The integer quotient is written to {_r1p_+_qxn_, _s2n_} and in addition _qxn_ fraction limbs are developed and written to {_r1p_, _qxn_}. Either or both _s2n_ and _qxn_ can be zero. For most usages, _qxn_ will be zero.

mpn*divmod_1 exists for upward source compatibility and is simply a macro calling mpn_divrem_1 with a \_qxn* of 0.

The areas at _r1p_ and _s2p_ have to be identical or completely separate, not partially overlapping.

mp*limb_t mpn_divmod (\_mp limb t \*r1p, mp limb t \*rs2p, mp size t rs2n,* \[Function\] _const mp limb t \*s3p, mp size t s3n_)

\[This function is obsolete. Please call mpn_tdiv_qr instead for best performance.\]

void mpn*divexact_1 (\_mp limb t \* rp, const mp limb t \* sp, mp size t n,* \[Function\] _mp limb t d_)

Divide {_sp_, _n_} by _d_, expecting it to divide exactly, and writing the result to {_rp_, _n_}. If _d_ doesn't divide exactly, the value written to {_rp_, _n_} is undefined. The areas at _rp_ and _sp_ have to be identical or completely separate, not partially overlapping.

mp*limb_t mpn_divexact_by3 (\_mp limb t \*rp, mp limb t \*sp, mp size t n*) \[Macro\] mp*limb_t mpn_divexact_by3c (\_mp limb t \*rp, mp limb t \*sp,* \[Function\] _mp size t n, mp limb t carry_)

Divide {_sp_, _n_} by 3, expecting it to divide exactly, and writing the result to {_rp_, _n_}. If 3 divides exactly, the return value is zero and the result is the quotient. If not, the return value is non-zero and the result won't be anything useful.

mpn_divexact_by3c takes an initial carry parameter, which can be the return value from a previous call, so a large calculation can be done piece by piece from low to high. mpn_divexact_by3 is simply a macro calling mpn_divexact_by3c with a 0 carry parameter.

These routines use a multiply-by-inverse and will be faster than mpn_divrem_1 on CPUs with fast multiplication but slow division.

The source _a_, result _q_, size _n_, initial carry _i_, and return value _c_ satisfy _cb<sup>n</sup>_ +*a*−*i* \= 3*q*, where _b_ \= 2<sup>GMP NUMB BITS</sup>. The return _c_ is always 0, 1 or 2, and the initial carry _i_ must also be 0, 1 or 2 (these are both borrows really). When _c_ \= 0 clearly _q_ \= (_a_ − _i_)_/\_3\. When \_c_ 6= 0, the remainder (_a_ − _i_) mod 3 is given by 3 − _c_, because _b_ ≡ 1 mod 3 (when mp_bits_per_limb is even, which is always so currently).

mp*limb_t mpn_mod_1 (\_const mp limb t \*s1p, mp size t s1n, mp limb t* \[Function\] _s2limb_)

Divide {_s1p_, _s1n_} by _s2limb_, and return the remainder. _s1n_ can be zero.

mp*limb_t mpn_lshift (\_mp limb t \*rp, const mp limb t \*sp, mp size t n,* \[Function\] _unsigned int count_)

Shift {_sp_, _n_} left by _count_ bits, and write the result to {_rp_, _n_}. The bits shifted out at the left are returned in the least significant _count_ bits of the return value (the rest of the return value is zero).

_count_ must be in the range 1 to mp*bits_per_limb − 1. The regions {\_sp*, _n_} and {_rp_, _n_} may overlap, provided _rp_ ≥ _sp_.

This function is written in assembly for most CPUs.

mp*limb_t mpn_rshift (\_mp limb t \*rp, const mp limb t \*sp, mp size t n,* \[Function\] _unsigned int count_)

Shift {_sp_, _n_} right by _count_ bits, and write the result to {_rp_, _n_}. The bits shifted out at the right are returned in the most significant _count_ bits of the return value (the rest of the return value is zero).

_count_ must be in the range 1 to mp*bits_per_limb − 1. The regions {\_sp*, _n_} and {_rp_, _n_} may overlap, provided _rp_ ≤ _sp_.

This function is written in assembly for most CPUs.

int mpn*cmp (\_const mp limb t \*s1p, const mp limb t \*s2p, mp size t n*) \[Function\] Compare {_s1p_, _n_} and {_s2p_, _n_} and return a positive value if _s1 > s2_, 0 if they are equal, or a negative value if _s1 < s2_.

int mpn*zero_p (\_const mp limb t \*sp, mp size t n*) \[Function\]

Test {_sp_, _n_} and return 1 if the operand is zero, 0 otherwise.

mp*size_t mpn_gcd (\_mp limb t \*rp, mp limb t \*xp, mp size t xn,* \[Function\] _mp limb t \*yp, mp size t yn_)

Set {_rp_, _retval_} to the greatest common divisor of {_xp_, _xn_} and {_yp_, _yn_}. The result can be up to _yn_ limbs, the return value is the actual number produced. Both source operands are destroyed.

It is required that _xn_ ≥ _yn >_ 0, the most significant limb of {_yp_, _yn_} must be non-zero, and at least one of the two operands must be odd. No overlap is permitted between {_xp_, _xn_} and {_yp_, _yn_}.

mp*limb_t mpn_gcd_1 (\_const mp limb t \*xp, mp size t xn, mp limb t* \[Function\]

_ylimb_)

Return the greatest common divisor of {_xp_, _xn_} and _ylimb_. Both operands must be non-zero.

mp*size_t mpn_gcdext (\_mp limb t \*gp, mp limb t \*sp, mp size t \*sn,* \[Function\] _mp limb t \*up, mp size t un, mp limb t \*vp, mp size t vn_) Let _U_ be defined by {_up_, _un_} and let _V_ be defined by {_vp_, _vn_}.

Compute the greatest common divisor _G_ of _U_ and _V_ . Compute a cofactor _S_ such that

_G_ \= _US_ \+ _V T_. The second cofactor _T_ is not computed but can easily be obtained from (_G_ − _US_)_/V_ (the division will be exact). It is required that _un_ ≥ _vn >_ 0, and the most significant limb of {_vp_, _vn_} must be non-zero.

_S_ satisfies _S_ \= 1 or |_S_| _< V/_(2*G*). _S_ \= 0 if and only if _V_ divides _U_ (i.e., _G_ \= _V_ ).

Store _G_ at _gp_ and let the return value define its limb count. Store _S_ at _sp_ and let |\*_sn_| define its limb count. _S_ can be negative; when this happens \*_sn_ will be negative. The area at _gp_ should have room for _vn_ limbs and the area at _sp_ should have room for _vn_ \+ 1 limbs.

Both source operands are destroyed.

Compatibility notes: GMP 4.3.0 and 4.3.1 defined _S_ less strictly. Earlier as well as later GMP releases define _S_ as described here. GMP releases before GMP 4.3.0 required additional space for both input and output areas. More precisely, the areas {_up_, _un_+1} and {_vp_, _vn_+1} were destroyed (i.e. the operands plus an extra limb past the end of each), and the areas pointed to by _gp_ and _sp_ should each have room for _un_ \+ 1 limbs.

mp*size_t mpn_sqrtrem (\_mp limb t \*r1p, mp limb t \*r2p, const* \[Function\] _mp limb t \*sp, mp size t n_)

Compute the square root of {_sp_, _n_} and put the result at {_r1p_, d*n/\_2e} and the remainder at {\_r2p*, _retval_}. _r2p_ needs space for _n_ limbs, but the return value indicates how many are produced.

The most significant limb of {_sp_, _n_} must be non-zero. The areas {_r1p_, d*n/\_2e} and {\_sp*, _n_} must be completely separate. The areas {_r2p_, _n_} and {_sp_, _n_} must be either identical or completely separate.

If the remainder is not wanted then _r2p_ can be NULL, and in this case the return value is zero or non-zero according to whether the remainder would have been zero or non-zero.

A return value of zero indicates a perfect square. See also mpn_perfect_square_p.

size*t mpn_sizeinbase (\_const mp limb t \*xp, mp size t n, int base*) \[Function\] Return the size of {_xp_,_n_} measured in number of digits in the given _base_. _base_ can vary from 2 to 62. Requires _n >_ 0 and _xp_\[_n_ − 1\] _\>_ 0\. The result will be either exact or 1 too big. If _base_ is a power of 2, the result is always exact.

mp*size_t mpn_get_str (\_unsigned char \*str, int base, mp limb t \*s1p,* \[Function\] _mp size t s1n_)

Convert {_s1p_, _s1n_} to a raw unsigned char array at _str_ in base _base_, and return the number of characters produced. There may be leading zeros in the string. The string is not in ASCII; to convert it to printable format, add the ASCII codes for '0' or 'A', depending on the base and range. _base_ can vary from 2 to 256.

The most significant limb of the input {_s1p_, _s1n_} must be non-zero. The input {_s1p_, _s1n_} is clobbered, except when _base_ is a power of 2, in which case it's unchanged.

The area at _str_ has to have space for the largest possible number represented by a _s1n_ long limb array, plus one extra character.

mp*size_t mpn_set_str (\_mp limb t \*rp, const unsigned char \*str, size t* \[Function\] _strsize, int base_)

Convert bytes {_str_,_strsize_} in the given _base_ to limbs at _rp_.

_str_\[0\] is the most significant input byte and _str_\[_strsize_ −1\] is the least significant input byte. Each byte should be a value in the range 0 to _base_ − 1, not an ASCII character. _base_ can vary from 2 to 256.

The converted value is {_rp_,_rn_} where _rn_ is the return value. If the most significant input byte _str_\[0\] is non-zero, then _rp_\[_rn_ − 1\] will be non-zero, else _rp_\[_rn_ − 1\] and some number of subsequent limbs may be zero.

The area at _rp_ has to have space for the largest possible number with _strsize_ digits in the chosen base, plus one extra limb.

The input must have at least one byte, and no overlap is permitted between {_str_,_strsize_} and the result at _rp_.

mp*bitcnt_t mpn_scan0 (\_const mp limb t \*s1p, mp bitcnt t bit*) \[Function\]

Scan _s1p_ from bit position _bit_ for the next clear bit.

It is required that there be a clear bit within the area at _s1p_ at or beyond bit position _bit_, so that the function has something to return.

mp*bitcnt_t mpn_scan1 (\_const mp limb t \*s1p, mp bitcnt t bit*) \[Function\]

Scan _s1p_ from bit position _bit_ for the next set bit.

It is required that there be a set bit within the area at _s1p_ at or beyond bit position _bit_, so that the function has something to return.

void mpn*random (\_mp limb t \*r1p, mp size t r1n*) \[Function\] void mpn*random2 (\_mp limb t \*r1p, mp size t r1n*) \[Function\]

Generate a random number of length _r1n_ and store it at _r1p_. The most significant limb is always non-zero. mpn_random generates uniformly distributed limb data, mpn_random2 generates long strings of zeros and ones in the binary representation.

mpn_random2 is intended for testing the correctness of the mpn routines.

mp*bitcnt_t mpn_popcount (\_const mp limb t \*s1p, mp size t n*) \[Function\]

Count the number of set bits in {_s1p_, _n_}.

mp*bitcnt_t mpn_hamdist (\_const mp limb t \*s1p, const mp limb t \*s2p,* \[Function\] _mp size t n_)

Compute the hamming distance between {_s1p_, _n_} and {_s2p_, _n_}, which is the number of bit positions where the two operands have different bit values.

int mpn*perfect_square_p (\_const mp limb t \*s1p, mp size t n*) \[Function\]

Return non-zero iff {_s1p_, _n_} is a perfect square. The most significant limb of the input {_s1p_, _n_} must be non-zero.

void mpn*and_n (\_mp limb t \*rp, const mp limb t \*s1p, const mp limb t* \[Function\] _\*s2p, mp size t n_)

Perform the bitwise logical and of {_s1p_, _n_} and {_s2p_, _n_}, and write the result to {_rp_, _n_}.

void mpn*ior_n (\_mp limb t \*rp, const mp limb t \*s1p, const mp limb t* \[Function\] _\*s2p, mp size t n_)

Perform the bitwise logical inclusive or of {_s1p_, _n_} and {_s2p_, _n_}, and write the result to {_rp_, _n_}.

void mpn*xor_n (\_mp limb t \*rp, const mp limb t \*s1p, const mp limb t* \[Function\] _\*s2p, mp size t n_)

Perform the bitwise logical exclusive or of {_s1p_, _n_} and {_s2p_, _n_}, and write the result to {_rp_, _n_}.

void mpn*andn_n (\_mp limb t \*rp, const mp limb t \*s1p, const mp limb t* \[Function\] _\*s2p, mp size t n_)

Perform the bitwise logical and of {_s1p_, _n_} and the bitwise complement of {_s2p_, _n_}, and write the result to {_rp_, _n_}.

void mpn*iorn_n (\_mp limb t \*rp, const mp limb t \*s1p, const mp limb t* \[Function\] _\*s2p, mp size t n_)

Perform the bitwise logical inclusive or of {_s1p_, _n_} and the bitwise complement of {_s2p_, _n_}, and write the result to {_rp_, _n_}.

void mpn*nand_n (\_mp limb t \*rp, const mp limb t \*s1p, const mp limb t* \[Function\] _\*s2p, mp size t n_)

Perform the bitwise logical and of {_s1p_, _n_} and {_s2p_, _n_}, and write the bitwise complement of the result to {_rp_, _n_}.

void mpn*nior_n (\_mp limb t \*rp, const mp limb t \*s1p, const mp limb t* \[Function\] _\*s2p, mp size t n_)

Perform the bitwise logical inclusive or of {_s1p_, _n_} and {_s2p_, _n_}, and write the bitwise complement of the result to {_rp_, _n_}.

void mpn*xnor_n (\_mp limb t \*rp, const mp limb t \*s1p, const mp limb t* \[Function\] _\*s2p, mp size t n_)

Perform the bitwise logical exclusive or of {_s1p_, _n_} and {_s2p_, _n_}, and write the bitwise complement of the result to {_rp_, _n_}.

void mpn*com (\_mp limb t \*rp, const mp limb t \*sp, mp size t n*) \[Function\]

Perform the bitwise complement of {_sp_, _n_}, and write the result to {_rp_, _n_}.

| void mpn*copyi (\_mp limb t \*rp, const mp limb t \*s1p, mp size t n*) Copy from {_s1p_, _n_} to {_rp_, _n_}, increasingly. | \[Function\] |
| --------------------------------------------------------------------------------------------------------------------------- | ------------ |
| void mpn*copyd (\_mp limb t \*rp, const mp limb t \*s1p, mp size t n*) Copy from {_s1p_, _n_} to {_rp_, _n_}, decreasingly. | \[Function\] |
| void mpn*zero (\_mp limb t \*rp, mp size t n*)                                                                              | \[Function\] |

Zero {_rp_, _n_}.

## 8.1 Low-level functions for cryptography

The functions prefixed with mpn*sec* and mpn*cnd* are designed to perform the exact same low-level operations and have the same cache access patterns for any two same-size arguments, assuming that function arguments are placed at the same position and that the machine state is identical upon function entry. These functions are intended for cryptographic purposes, where resilience to side-channel attacks is desired.

These functions are less efficient than their "leaky" counterparts; their performance for operands of the sizes typically used for cryptographic applications is between 15% and 100% worse. For larger operands, these functions might be inadequate, since they rely on asymptotically elementary algorithms.

These functions do not make any explicit allocations. Those of these functions that need scratch space accept a scratch space operand. This convention allows callers to keep sensitive data in designated memory areas. Note however that compilers may choose to spill scalar values used within these functions to their stack frame and that such scalars may contain sensitive data.

In addition to these specially crafted functions, the following mpn functions are naturally sidechannel resistant: mpn_add_n, mpn_sub_n, mpn_lshift, mpn_rshift, mpn_zero, mpn_copyi, mpn_copyd, mpn_com, and the logical function (mpn_and_n, etc).

There are some exceptions from the side-channel resilience: (1) Some assembly implementations of mpn_lshift identify shift-by-one as a special case. This is a problem iff the shift count is a function of sensitive data. (2) Alpha ev6 and Pentium4 using 64-bit limbs have leaky mpn_add_n and mpn_sub_n. (3) Alpha ev6 has a leaky mpn_mul_1 which also makes mpn_sec_mul on those systems unsafe.

mp*limb_t mpn_cnd_add_n (\_mp limb t cnd, mp limb t \*rp, const* \[Function\] _mp limb t \*s1p, const mp limb t \*s2p, mp size t n_)

mp*limb_t mpn_cnd_sub_n (\_mp limb t cnd, mp limb t \*rp, const* \[Function\] _mp limb t \*s1p, const mp limb t \*s2p, mp size t n_)

These functions do conditional addition and subtraction. If _cnd_ is non-zero, they produce the same result as a regular mpn*add_n or mpn_sub_n, and if \_cnd* is zero, they copy {_s1p_,_n_} to the result area and return zero. The functions are designed to have timing and memory access patterns depending only on size and location of the data areas, but independent of the condition _cnd_. Like for mpn_add_n and mpn_sub_n, on most machines, the timing will also be independent of the actual limb values.

mp*limb_t mpn_sec_add_1 (\_mp limb t \*rp, const mp limb t \*ap, mp size t* \[Function\] _n, mp limb t b, mp limb t \*tp_)

mp*limb_t mpn_sec_sub_1 (\_mp limb t \*rp, const mp limb t \*ap, mp size t* \[Function\] _n, mp limb t b, mp limb t \*tp_)

Set _R_ to _A_ \+ _b_ or _A_ \- _b_, respectively, where _R_ \= {_rp_,_n_}, _A_ \= {_ap_,_n_}, and _b_ is a single limb. Returns carry.

These functions take _O_(_N_) time, unlike the leaky functions mpn*add_1 which are \_O*(1) on average. They require scratch space of mpn*sec_add_1_itch(\_n*) and mpn*sec_sub_1_itch(\_n*) limbs, respectively, to be passed in the _tp_ parameter. The scratch space requirements are guaranteed to be at most _n_ limbs, and increase monotonously in the operand size.

void mpn*cnd_swap (\_mp limb t cnd, volatile mp limb t \*ap, volatile* \[Function\] _mp limb t \*bp, mp size t n_)

If _cnd_ is non-zero, swaps the contents of the areas {_ap_,_n_} and {_bp_,_n_}. Otherwise, the areas are left unmodified. Implemented using logical operations on the limbs, with the same memory accesses independent of the value of _cnd_.

void mpn*sec_mul (\_mp limb t \*rp, const mp limb t \*ap, mp size t an, const* \[Function\] _mp limb t \*bp, mp size t bn, mp limb t \*tp_)

mp*size_t mpn_sec_mul_itch (\_mp size t an, mp size t bn*) \[Function\] Set _R_ to _A_ × _B_, where _A_ \= {_ap_,_an_}, _B_ \= {_bp_,_bn_}, and _R_ \= {_rp_,_an_ \+ _bn_}.

It is required that _an_ ≥ _bn >_ 0.

No overlapping between _R_ and the input operands is allowed. For _A_ \= _B_, use mpn_sec_sqr for optimal performance.

This function requires scratch space of mpn*sec_mul_itch(\_an*,_bn_) limbs to be passed in the _tp_ parameter. The scratch space requirements are guaranteed to increase monotonously in the operand sizes.

| void mpn*sec_sqr (\_mp limb t \*rp, const mp limb t \*ap, mp size t an, mp limb t \*tp*) | \[Function\] |
| ---------------------------------------------------------------------------------------- | ------------ |
| mp*size_t mpn_sec_sqr_itch (\_mp size t an*)                                             | \[Function\] |

Set _R_ to _A_<sup>2</sup>, where _A_ \= {_ap_,_an_}, and _R_ \= {_rp_,2*an*}.

It is required that _an >_ 0.

No overlapping between _R_ and the input operands is allowed.

This function requires scratch space of mpn*sec_sqr_itch(\_an*) limbs to be passed in the _tp_ parameter. The scratch space requirements are guaranteed to increase monotonously in the operand size.

void mpn*sec_powm (\_mp limb t \*rp, const mp limb t \*bp, mp size t bn,* \[Function\] _const mp limb t \*ep, mp bitcnt t enb, const mp limb t \*mp, mp size t n, mp limb t \*tp_)

mp*size_t mpn_sec_powm_itch (\_mp size t bn, mp bitcnt t enb, size t n*) \[Function\] Set _R_ to _B<sup>E</sup>_ mod _M_, where _R_ \= {_rp_,_n_}, _M_ \= {_mp_,_n_}, and _E_ \= {_ep_,d_enb/\_GMP NUMB BITSe}.

It is required that _B >_ 0, that _M >_ 0 is odd, and that _E <_ 2*<sup>enb</sup>*, with _enb >_ 0.

No overlapping between _R_ and the input operands is allowed.

This function requires scratch space of mpn*sec_powm_itch(\_bn*,_enb_,_n_) limbs to be passed in the _tp_ parameter. The scratch space requirements are guaranteed to increase monotonously in the operand sizes.

void mpn*sec_tabselect (\_mp limb t \*rp, const mp limb t \*tab, mp size t* \[Function\] _n, mp size t nents, mp size t which_)

Select entry _which_ from table _tab_, which has _nents_ entries, each _n_ limbs. Store the selected entry at _rp_.

This function reads the entire table to avoid side-channel information leaks.

mp*limb_t mpn_sec_div_qr (\_mp limb t \*qp, mp limb t \*np, mp size t nn,* \[Function\] _const mp limb t \*dp, mp size t dn, mp limb t \*tp_)

mp*size_t mpn_sec_div_qr_itch (\_mp size t nn, mp size t dn*) \[Function\] Set _Q_ to b*N/D_c and \_R* to _N_ mod _D_, where _N_ \= {_np_,_nn_}, _D_ \= {_dp_,_dn_}, _Q_'s most significant limb is the function return value and the remaining limbs are {_qp_,_nn-dn_}, and _R_ \= {_np_,_dn_}.

It is required that _nn_ ≥ _dn_ ≥ 1, and that _dp_\[_dn_ − 1\] 6= 0. This does not imply that _N_ ≥ _D_ since _N_ might be zero-padded.

Note the overlapping between _N_ and _R_. No other operand overlapping is allowed. The entire space occupied by _N_ is overwritten.

This function requires scratch space of mpn*sec_div_qr_itch(\_nn*,_dn_) limbs to be passed in the _tp_ parameter.

void mpn*sec_div_r (\_mp limb t \*np, mp size t nn, const mp limb t \*dp,* \[Function\] _mp size t dn, mp limb t \*tp_)

mp*size_t mpn_sec_div_r_itch (\_mp size t nn, mp size t dn*) \[Function\] Set _R_ to _N_ mod _D_, where _N_ \= {_np_,_nn_}, _D_ \= {_dp_,_dn_}, and _R_ \= {_np_,_dn_}.

It is required that _nn_ ≥ _dn_ ≥ 1, and that _dp_\[_dn_ − 1\] 6= 0. This does not imply that _N_ ≥ _D_ since _N_ might be zero-padded.

Note the overlapping between _N_ and _R_. No other operand overlapping is allowed. The entire space occupied by _N_ is overwritten.

This function requires scratch space of mpn*sec_div_r_itch(\_nn*,_dn_) limbs to be passed in the _tp_ parameter.

int mpn*sec_invert (\_mp limb t \*rp, mp limb t \*ap, const mp limb t \*mp,* \[Function\] _mp size t n, mp bitcnt t nbcnt, mp limb t \*tp_)

mp*size_t mpn_sec_invert_itch (\_mp size t n*) \[Function\]

Set _R_ to _A_<sup>−1</sup> mod _M_, where _R_ \= {_rp_,_n_}, _A_ \= {_ap_,_n_}, and _M_ \= {_mp_,_n_}. This function's interface is preliminary.

If an inverse exists, return 1, otherwise return 0 and leave _R_ undefined. In either case, the input _A_ is destroyed.

It is required that _M_ is odd, and that _nbcnt_ ≥ dlog(_A_ \+ 1)e + dlog(_M_ \+ 1)e. A safe choice is _nbcnt_ \= 2*n* × GMP NUMB BITS, but a smaller value might improve performance if _M_ or _A_ are known to have leading zero bits.

This function requires scratch space of mpn*sec_invert_itch(\_n*) limbs to be passed in the _tp_ parameter.

## 8.2 Nails

Everything in this section is highly experimental and may disappear or be subject to incompatible changes in a future version of GMP.

Nails are an experimental feature whereby a few bits are left unused at the top of each mp*limb* t. This can significantly improve carry handling on some processors.

All the mpn functions accepting limb data will expect the nail bits to be zero on entry, and will return data with the nails similarly all zero. This applies both to limb vectors and to single limb arguments.

Nails can be enabled by configuring with '--enable-nails'. By default the number of bits will be chosen according to what suits the host processor, but a particular number can be selected with '--enable-nails=N'.

At the mpn level, a nail build is neither source nor binary compatible with a non-nail build, strictly speaking. But programs acting on limbs only through the mpn functions are likely to work equally well with either build, and judicious use of the definitions below should make any program compatible with either build, at the source level.

For the higher level routines, meaning mpz etc, a nail build should be fully source and binary compatible with a non-nail build.

| GMP_NAIL_BITS | \[Macro\] |
| ------------- | --------- |
| GMP_NUMB_BITS | \[Macro\] |

GMP_LIMB_BITS \[Macro\]

GMP_NAIL_BITS is the number of nail bits, or 0 when nails are not in use. GMP_NUMB_BITS is the number of data bits in a limb. GMP_LIMB_BITS is the total number of bits in an mp_limb_t. In all cases

GMP_LIMB_BITS == GMP_NAIL_BITS + GMP_NUMB_BITS

GMP_NAIL_MASK \[Macro\]

GMP_NUMB_MASK \[Macro\]

Bit masks for the nail and number parts of a limb. GMP_NAIL_MASK is 0 when nails are not in use.

GMP*NAIL_MASK is not often needed, since the nail part can be obtained with x>>GMP_NUMB* BITS, and that means one less large constant, which can help various RISC chips.

GMP_NUMB_MAX \[Macro\]

The maximum value that can be stored in the number part of a limb. This is the same as GMP_NUMB_MASK, but can be used for clarity when doing comparisons rather than bit-wise operations.

The term "nails" comes from finger or toe nails, which are at the ends of a limb (arm or leg). "numb" is short for number, but is also how the developers felt after trying for a long time to come up with sensible names for these things.

In the future (the distant future most likely) a non-zero nail might be permitted, giving nonunique representations for numbers in a limb vector. This would help vector processors since carries would only ever need to propagate one or two limbs.

# 9 Random Number Functions

Sequences of pseudo-random numbers in GMP are generated using a variable of type gmp_randstate_t, which holds an algorithm selection and a current state. Such a variable must be initialized by a call to one of the gmp_randinit functions, and can be seeded with one of the gmp_randseed functions.

The functions actually generating random numbers are described in Section 5.13 \[Integer Random Numbers\], page 42, and Section 7.8 \[Miscellaneous Float Functions\], page 58.

The older style random number functions don't accept a gmp_randstate_t parameter but instead share a global variable of that type. They use a default algorithm and are currently not seeded (though perhaps that will change in the future). The new functions accepting a gmp_randstate_t are recommended for applications that care about randomness.

## 9.1 Random State Initialization

void gmp*randinit_default (\_gmp randstate t state*) \[Function\]

Initialize _state_ with a default algorithm. This will be a compromise between speed and randomness, and is recommended for applications with no special requirements. Currently this is gmp_randinit_mt.

void gmp*randinit_mt (\_gmp randstate t state*) \[Function\]

Initialize _state_ for a Mersenne Twister algorithm. This algorithm is fast and has good randomness properties.

void gmp*randinit_lc_2exp (\_gmp randstate t state, const mpz t a,* \[Function\] _unsigned long c, mp bitcnt t m2exp_)

Initialize _state_ with a linear congruential algorithm _X_ \= (_aX_ \+ _c_) mod 2*<sup>m</sup>*<sup>2</sup>_<sup>exp</sup>_.

The low bits of _X_ in this algorithm are not very random. The least significant bit will have a period no more than 2, and the second bit no more than 4, etc. For this reason only the high half of each _X_ is actually used.

When a random number of more than \_m2exp/\_2 bits is to be generated, multiple iterations of the recurrence are used and the results concatenated.

int gmp*randinit_lc_2exp_size (\_gmp randstate t state, mp bitcnt t* \[Function\] _size_)

Initialize _state_ for a linear congruential algorithm as per gmp*randinit_lc_2exp. \_a*, _c_ and _m2exp_ are selected from a table, chosen so that _size_ bits (or more) of each _X_ will be used, i.e._m2exp/\_2 ≥ \_size_.

If successful the return value is non-zero. If _size_ is bigger than the table data provides then the return value is zero. The maximum _size_ currently supported is 128.

| void gmp*randinit_set (\_gmp randstate t rop, gmp randstate t op*) Initialize _rop_ with a copy of the algorithm and state from _op_. | \[Function\] |
| ------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| void gmp*randinit (\_gmp randstate t state, gmp randalg t alg, . . .*)<br><br>This function is obsolete.                              | \[Function\] |

Initialize _state_ with an algorithm selected by _alg_. The only choice is GMP_RAND_ALG_LC, which is gmp_randinit_lc_2exp_size described above. A third parameter of type unsignedlong

Chapter 9: Random Number Functions

is required, this is the _size_ for that function. GMP_RAND_ALG_DEFAULT and 0 are the same as GMP_RAND_ALG_LC.

gmp*randinit sets bits in the global variable gmp_errno to indicate an error. GMP_ERROR* UNSUPPORTED*ARGUMENT if \_alg* is unsupported, or GMP*ERROR_INVALID_ARGUMENT if the \_size* parameter is too big. It may be noted this error reporting is not thread safe (a good reason to use gmp_randinit_lc_2exp_size instead).

void gmp*randclear (\_gmp randstate t state*) \[Function\]

Free all memory occupied by _state_.

## 9.2 Random State Seeding

void gmp*randseed (\_gmp randstate t state, const mpz t seed*) \[Function\] void gmp*randseed_ui (\_gmp randstate t state, unsigned long int seed*) \[Function\] Set an initial seed value into _state_.

The size of a seed determines how many different sequences of random numbers it's possible to generate. The "quality" of the seed is the randomness of a given seed compared to the previous seed used, and this affects the randomness of separate number sequences. The method for choosing a seed is critical if the generated numbers are to be used for important applications, such as generating cryptographic keys.

Traditionally the system time has been used to seed, but care needs to be taken with this. If an application seeds often and the resolution of the system clock is low, then the same sequence of numbers might be repeated. Also, the system time is quite easy to guess, so if unpredictability is required then it should definitely not be the only source for the seed value. On some systems there's a special device /dev/random which provides random data better suited for use as a seed.

## 9.3 Random State Miscellaneous

unsigned long gmp*urandomb_ui (\_gmp randstate t state, unsigned long* \[Function\] _n_)

Return a uniformly distributed random number of _n_ bits, i.e. in the range 0 to 2*<sup>n</sup>*−1 inclusive. _n_ must be less than or equal to the number of bits in an unsignedlong.

unsigned long gmp*urandomm_ui (\_gmp randstate t state, unsigned long* \[Function\] _n_)

Return a uniformly distributed random number in the range 0 to _n_ − 1, inclusive.

# 10 Formatted Output

## 10.1 Format Strings

gmp*printf and friends accept format strings similar to the standard C printf (see Section "Formatted Output" in \_The GNU C Library Reference Manual*). A format specification is of the form

% \[flags\] \[width\] \[.\[precision\]\] \[type\] conv

GMP adds types 'Z', 'Q' and 'F' for mpz_t, mpq_t and mpf_t respectively, 'M' for mp_limb_t, and 'N' for an mp_limb_t array. 'Z', 'Q', 'M' and 'N' behave like integers. 'Q' will print a '/' and a denominator, if needed. 'F' behaves like a float. For example,

mpz_t z; gmp_printf ("%s is an mpz %Zd\\n", "here", z);

mpq_t q; gmp_printf ("a hex rational: %#40Qx\\n", q);

mpf_t f; int n;

gmp_printf ("fixed point mpf %.\*Ff with %d digits\\n", n, f, n);

mp_limb_t l; gmp_printf ("limb %Mu\\n", l);

const mp_limb_t \*ptr; mp_size_t size;

gmp_printf ("limb array %Nx\\n", ptr, size);

For 'N' the limbs are expected least significant first, as per the mpn functions (see Chapter 8 \[Low-level Functions\], page 60). A negative size can be given to print the value as a negative.

All the standard C printf types behave the same as the C library printf, and can be freely intermixed with the GMP extensions. In the current implementation the standard parts of the format string are simply handed to printf and only the GMP extensions handled directly.

The flags accepted are as follows. GLIBC style ''' is only for the standard C types (not the GMP types), and only if the C library supports it.

0 pad with zeros (rather than spaces)

\# show the base with '0x', '0X' or '0'

\+ always show a sign

(space) show a space or a '-' sign

' group digits, GLIBC style (not GMP types)

The optional width and precision can be given as a number within the format string, or as a '\*' to take an extra parameter of type int, the same as the standard printf.

The standard types accepted are as follows. 'h' and 'l' are portable, the rest will depend on the compiler (or include files) for the type and the C library for the output.

h short hh char Chapter 10: Formatted Output

j intmax_t or uintmax_t l long or wchar_t ll longlong L longdouble q quad_t or u_quad_t t ptrdiff_t z size_t

The GMP types are

F mpf_t, float conversions

Q mpq_t, integer conversions

- mp_limb_t, integer conversions
- mp_limb_t array, integer conversions Z mpz_t, integer conversions

The conversions accepted are as follows. 'a' and 'A' are always supported for mpf_t but depend on the C library for standard C float types. 'm' and 'p' depend on the C library.

aA hex floats, C99 style c character d decimal integer

eE scientific format float f fixed point float i same as d

gG fixed or scientific float m strerror string, GLIBC style n store characters written so far o octal integer p pointer s string

u unsigned integer xX hex integer

'o', 'x' and 'X' are unsigned for the standard C types, but for types 'Z', 'Q' and 'N' they are signed. 'u' is not meaningful for 'Z', 'Q' and 'N'.

'M' is a proxy for the C library 'l' or 'L', according to the size of mp_limb_t. Unsigned conversions will be usual, but a signed conversion can be used and will interpret the value as a two's complement negative.

'n' can be used with any type, even the GMP types.

Other types or conversions that might be accepted by the C library printf cannot be used through gmp*printf, this includes for instance extensions registered with GLIBC register* printf_function. Also currently there's no support for POSIX '\$' style numbered arguments (perhaps this will be added in the future).

The precision field has its usual meaning for integer 'Z' and float 'F' types, but is currently undefined for 'Q' and should not be used with that.

mpf_t conversions only ever generate as many digits as can be accurately represented by the operand, the same as mpf_get_str does. Zeros will be used if necessary to pad to the requested precision. This happens even for an 'f' conversion of an mpf_t which is an integer, for instance 2<sup>1024</sup> in an mpf_t of 128 bits precision will only produce about 40 digits, then pad with zeros to the decimal point. An empty precision field like '%.Fe' or '%.Ff' can be used to specifically request just the significant digits. Without any dot and thus no precision field, a precision value of 6 will be used. Note that these rules mean that '%Ff', '%.Ff', and '%.0Ff' will all be different.

The decimal point character (or string) is taken from the current locale settings on systems which provide localeconv (see Section "Locales and Internationalization" in _The GNU C Library Reference Manual_). The C library will normally do the same for standard float output.

The format string is only interpreted as plain chars, multibyte characters are not recognised. Perhaps this will change in the future.

## 10.2 Functions

Each of the following functions is similar to the corresponding C library function. The basic printf forms take a variable argument list. The vprintf forms take an argument pointer, see Section "Variadic Functions" in _The GNU C Library Reference Manual_, or 'man3va_start'.

It should be emphasised that if a format string is invalid, or the arguments don't match what the format specifies, then the behaviour of any of these functions will be unpredictable. GCC format string checking is not available, since it doesn't recognise the GMP extensions.

The file based functions gmp_printf and gmp_fprintf will return −1 to indicate a write error. Output is not "atomic", so partial output may be produced if a write error occurs. All the functions can return −1 if the C library printf variant in use returns −1, but this shouldn't normally occur.

int gmp*printf (\_const char \*fmt, . . .*) \[Function\] int gmp*vprintf (\_const char \*fmt, va list ap*) \[Function\]

Print to the standard output stdout. Return the number of characters written, or −1 if an error occurred.

int gmp*fprintf (\_FILE \*fp, const char \*fmt, . . .*) \[Function\] int gmp*vfprintf (\_FILE \*fp, const char \*fmt, va list ap*) \[Function\]

Print to the stream _fp_. Return the number of characters written, or −1 if an error occurred.

int gmp*sprintf (\_char \*buf, const char \*fmt, . . .*) \[Function\] int gmp*vsprintf (\_char \*buf, const char \*fmt, va list ap*) \[Function\]

Form a null-terminated string in _buf_. Return the number of characters written, excluding the terminating null.

No overlap is permitted between the space at _buf_ and the string _fmt_.

These functions are not recommended, since there's no protection against exceeding the space available at _buf_.

int gmp*snprintf (\_char \*buf, size t size, const char \*fmt, . . .*) \[Function\] int gmp*vsnprintf (\_char \*buf, size t size, const char \*fmt, va list ap*) \[Function\] Form a null-terminated string in _buf_. No more than _size_ bytes will be written. To get the full output, _size_ must be enough for the string and null-terminator.

The return value is the total number of characters which ought to have been produced, excluding the terminating null. If _retval_ ≥ _size_ then the actual output has been truncated to the first _size_ − 1 characters, and a null appended.

No overlap is permitted between the region {_buf_,_size_} and the _fmt_ string.

Chapter 10: Formatted Output

Notice the return value is in ISO C99 snprintf style. This is so even if the C library vsnprintf is the older GLIBC 2.0.x style.

int gmp*asprintf (\_char \*\*pp, const char \*fmt, . . .*) \[Function\] int gmp*vasprintf (\_char \*\*pp, const char \*fmt, va list ap*) \[Function\] Form a null-terminated string in a block of memory obtained from the current memory allocation function (see Chapter 13 \[Custom Allocation\], page 92). The block will be the size of the string and null-terminator. The address of the block is stored to \*_pp_. The return value is the number of characters produced, excluding the null-terminator.

Unlike the C library asprintf, gmp_asprintf doesn't return −1 if there's no more memory available, it lets the current allocation function handle that.

int gmp*obstack_printf (\_struct obstack \*ob, const char \*fmt, . . .*) \[Function\] int gmp*obstack_vprintf (\_struct obstack \*ob, const char \*fmt, va list ap*) \[Function\] Append to the current object in _ob_. The return value is the number of characters written. A null-terminator is not written.

_fmt_ cannot be within the current object in _ob_, since that object might move as it grows.

These functions are available only when the C library provides the obstack feature, which probably means only on GNU systems, see Section "Obstacks" in _The GNU C Library Reference Manual_.

## 10.3 C++ Formatted Output

The following functions are provided in libgmpxx (see Section 3.1 \[Headers and Libraries\], page 17), which is built if C++ support is enabled (see Section 2.1 \[Build Options\], page 3). Prototypes are available from &lt;gmp.h&gt;.

ostream& operator<< (_ostream& stream, const mpz t op_) \[Function\]

Print _op_ to _stream_, using its ios formatting settings. ios::width is reset to 0 after output, the same as the standard ostreamoperator<< routines do.

In hex or octal, _op_ is printed as a signed number, the same as for decimal. This is unlike the standard operator<< routines on int etc, which instead give two's complement.

ostream& operator<< (_ostream& stream, const mpq t op_) \[Function\]

Print _op_ to _stream_, using its ios formatting settings. ios::width is reset to 0 after output, the same as the standard ostreamoperator<< routines do.

Output will be a fraction like '5/9', or if the denominator is 1 then just a plain integer like

'123'.

In hex or octal, _op_ is printed as a signed value, the same as for decimal. If ios::showbase is set then a base indicator is shown on both the numerator and denominator (if the denominator is required).

ostream& operator<< (_ostream& stream, const mpf t op_) \[Function\]

Print _op_ to _stream_, using its ios formatting settings. ios::width is reset to 0 after output, the same as the standard ostreamoperator<< routines do.

The decimal point follows the standard library float operator<<, which on recent systems means the std::locale imbued on _stream_.

Hex and octal are supported, unlike the standard operator<< on double. The mantissa will be in hex or octal, the exponent will be in decimal. For hex the exponent delimiter is an '@'. This is as per mpf_out_str.

ios::showbase is supported, and will put a base on the mantissa, for example hex '0x1.8' or '0x0.8', or octal '01.4' or '00.4'. This last form is slightly strange, but at least differentiates itself from decimal.

These operators mean that GMP types can be printed in the usual C++ way, for example,

mpz_t z; int n;

...

cout << "iteration " << n << " value " << z << "\\n";

But note that ostream output (and istream input, see Section 11.3 \[C++ Formatted Input\], page 81) is the only overloading available for the GMP types and that for instance using + with an mpz_t will have unpredictable results. For classes with overloading, see Chapter 12 \[C++ Class Interface\], page 83.

Chapter 11: Formatted Input

# 11 Formatted Input

## 11.1 Formatted Input Strings

gmp*scanf and friends accept format strings similar to the standard C scanf (see Section "Formatted Input" in \_The GNU C Library Reference Manual*). A format specification is of the form

% \[flags\] \[width\] \[type\] conv

GMP adds types 'Z', 'Q' and 'F' for mpz_t, mpq_t and mpf_t respectively. 'Z' and 'Q' behave like integers. 'Q' will read a '/' and a denominator, if present. 'F' behaves like a float.

GMP variables don't require an & when passed to gmp_scanf, since they're already "call-byreference". For example,

/\* to read say "a(5) = 1234" \*/ int n; mpz_t z; gmp_scanf ("a(%d) = %Zd\\n", &n, z);

mpq_t q1, q2; gmp_sscanf ("0377 + 0x10/0x11", "%Qi + %Qi", q1, q2);

/\* to read say "topleft (1.55,-2.66)" \*/ mpf_t x, y; char buf\[32\];

gmp_scanf ("%31s (%Ff,%Ff)", buf, x, y);

All the standard C scanf types behave the same as in the C library scanf, and can be freely intermixed with the GMP extensions. In the current implementation the standard parts of the format string are simply handed to scanf and only the GMP extensions handled directly.

The flags accepted are as follows. 'a' and ''' will depend on support from the C library, and ''' cannot be used with GMP types.

\* read but don't store

a allocate a buffer (string conversions)

' grouped digits, GLIBC style (not GMP types)

The standard types accepted are as follows. 'h' and 'l' are portable, the rest will depend on the compiler (or include files) for the type and the C library for the input.

h short hh char

j intmax_t or uintmax_t l longint, double or wchar_t ll longlong L longdouble q quad_t or u_quad_t t ptrdiff_t z size_t

The GMP types are

F mpf_t, float conversions

Q mpq_t, integer conversions

Z mpz_t, integer conversions

The conversions accepted are as follows. 'p' and '\[' will depend on support from the C library, the rest are standard.

c character or characters d decimal integer e E f g float

G

i integer with base indicator n characters read so far o octal integer p pointer

s string of non-whitespace characters u decimal integer xX hex integer

\[ string of characters in a set

'e', 'E', 'f', 'g' and 'G' are identical, they all read either fixed point or scientific format, and either upper or lower case 'e' for the exponent in scientific format.

C99 style hex float format (printf%a, see Section 10.1 \[Formatted Output Strings\], page 74) is always accepted for mpf_t, but for the standard float types it will depend on the C library.

'x' and 'X' are identical, both accept both upper and lower case hexadecimal.

'o', 'u', 'x' and 'X' all read positive or negative values. For the standard C types these are described as "unsigned" conversions, but that merely affects certain overflow handling, negatives are still allowed (per strtoul, see Section "Parsing of Integers" in _The GNU C Library Reference Manual_). For GMP types there are no overflows, so 'd' and 'u' are identical.

'Q' type reads the numerator and (optional) denominator as given. If the value might not be in canonical form then mpq_canonicalize must be called before using it in any calculations (see Chapter 6 \[Rational Number Functions\], page 47).

'Qi' will read a base specification separately for the numerator and denominator. For example '0x10/11' would be 16/11, whereas '0x10/0x11' would be 16/17.

'n' can be used with any of the types above, even the GMP types. '\*' to suppress assignment is allowed, though in that case it would do nothing at all.

Other conversions or types that might be accepted by the C library scanf cannot be used through gmp_scanf.

Whitespace is read and discarded before a field, except for 'c' and '\[' conversions.

For float conversions, the decimal point character (or string) expected is taken from the current locale settings on systems which provide localeconv (see Section "Locales and Internationalization" in _The GNU C Library Reference Manual_). The C library will normally do the same for standard float input.

The format string is only interpreted as plain chars, multibyte characters are not recognised. Perhaps this will change in the future.

Chapter 11: Formatted Input

## 11.2 Formatted Input Functions

Each of the following functions is similar to the corresponding C library function. The plain scanf forms take a variable argument list. The vscanf forms take an argument pointer, see Section "Variadic Functions" in _The GNU C Library Reference Manual_, or 'man3va_start'.

It should be emphasised that if a format string is invalid, or the arguments don't match what the format specifies, then the behaviour of any of these functions will be unpredictable. GCC format string checking is not available, since it doesn't recognise the GMP extensions.

No overlap is permitted between the _fmt_ string and any of the results produced.

int gmp*scanf (\_const char \*fmt, . . .*) \[Function\] int gmp*vscanf (\_const char \*fmt, va list ap*) \[Function\]

Read from the standard input stdin.

int gmp*fscanf (\_FILE \*fp, const char \*fmt, . . .*) \[Function\] int gmp*vfscanf (\_FILE \*fp, const char \*fmt, va list ap*) \[Function\]

Read from the stream _fp_.

int gmp*sscanf (\_const char \*s, const char \*fmt, . . .*) \[Function\] int gmp*vsscanf (\_const char \*s, const char \*fmt, va list ap*) \[Function\]

Read from a null-terminated string _s_.

The return value from each of these functions is the same as the standard C99 scanf, namely the number of fields successfully parsed and stored. '%n' fields and fields read but suppressed by '\*' don't count towards the return value.

If end of input (or a file error) is reached before a character for a field or a literal, and if no previous non-suppressed fields have matched, then the return value is EOF instead of 0. A whitespace character in the format string is only an optional match and doesn't induce an EOF in this fashion. Leading whitespace read and discarded for a field don't count as characters for that field.

For the GMP types, input parsing follows C99 rules, namely one character of lookahead is used and characters are read while they continue to meet the format requirements. If this doesn't provide a complete number then the function terminates, with that field not stored nor counted towards the return value. For instance with mpf_t an input '1.23e-XYZ' would be read up to the 'X' and that character pushed back since it's not a digit. The string '1.23e-' would then be considered invalid since an 'e' must be followed by at least one digit.

For the standard C types, in the current implementation GMP calls the C library scanf functions, which might have looser rules about what constitutes a valid input.

Note that gmp_sscanf is the same as gmp_fscanf and only does one character of lookahead when parsing. Although clearly it could look at its entire input, it is deliberately made identical to gmp_fscanf, the same way C99 sscanf is the same as fscanf.

## 11.3 C++ Formatted Input

The following functions are provided in libgmpxx (see Section 3.1 \[Headers and Libraries\], page 17), which is built only if C++ support is enabled (see Section 2.1 \[Build Options\], page 3). Prototypes are available from &lt;gmp.h&gt;.

istream& operator>> (_istream& stream, mpz t rop_) \[Function\]

Read _rop_ from _stream_, using its ios formatting settings.

istream& operator>> (_istream& stream, mpq t rop_) \[Function\]

An integer like '123' will be read, or a fraction like '5/9'. No whitespace is allowed around the '/'. If the fraction is not in canonical form then mpq_canonicalize must be called (see Chapter 6 \[Rational Number Functions\], page 47) before operating on it.

As per integer input, an '0' or '0x' base indicator is read when none of ios::dec, ios::oct or ios::hex are set. This is done separately for numerator and denominator, so that for instance '0x10/11' is 16*/\_11 and '0x10/0x11' is 16*/\_17.

istream& operator>> (_istream& stream, mpf t rop_) \[Function\]

Read _rop_ from _stream_, using its ios formatting settings.

Hex or octal floats are not supported, but might be in the future, or perhaps it's best to accept only what the standard float operator>> does.

Note that digit grouping specified by the istream locale is currently not accepted. Perhaps this will change in the future.

These operators mean that GMP types can be read in the usual C++ way, for example,

mpz_t z;

...

cin >> z;

But note that istream input (and ostream output, see Section 10.3 \[C++ Formatted Output\], page 77) is the only overloading available for the GMP types and that for instance using + with an mpz_t will have unpredictable results. For classes with overloading, see Chapter 12 \[C++ Class Interface\], page 83.

# 12 C++ Class Interface

This chapter describes the C++ class based interface to GMP.

All GMP C language types and functions can be used in C++ programs, since gmp.h has extern "C" qualifiers, but the class interface offers overloaded functions and operators which may be more convenient.

Due to the implementation of this interface, a reasonably recent C++ compiler is required, one supporting namespaces, partial specialization of templates and member templates.

Everything described in this chapter is to be considered preliminary and might be subject to incompatible changes if some unforeseen difficulty reveals itself.

## 12.1 C++ Interface General

All the C++ classes and functions are available with

# include &lt;gmpxx.h&gt;

Programs should be linked with the libgmpxx and libgmp libraries. For example, g++ mycxxprog.cc -lgmpxx -lgmp

The classes defined are

| mpz_class | \[Class\] |
| --------- | --------- |
| mpq_class | \[Class\] |
| mpf_class | \[Class\] |

The standard operators and various standard functions are overloaded to allow arithmetic with these classes. For example,

int main (void)

{ mpz_class a, b, c;

a = 1234; b = "-5678"; c = a+b; cout << "sum is " << c << "\\n"; cout << "absolute value is " << abs(c) << "\\n";

return 0;

}

An important feature of the implementation is that an expression like a=b+c results in a single call to the corresponding mpz_add, without using a temporary for the b+c part. Expressions which by their nature imply intermediate values, like a=b\*c+d\*e, still use temporaries though.

The classes can be freely intermixed in expressions, as can the classes and the standard types long, unsignedlong and double. Smaller types like int or float can also be intermixed, since C++ will promote them.

Note that bool is not accepted directly, but must be explicitly cast to an int first. This is because C++ will automatically convert any pointer to a bool, so if GMP accepted bool it would make all sorts of invalid class and pointer combinations compile but almost certainly not do anything sensible.

Conversions back from the classes to standard C++ types aren't done automatically, instead member functions like get_si are provided (see the following sections for details).

Also there are no automatic conversions from the classes to the corresponding GMP C types, instead a reference to the underlying C object can be obtained with the following functions,

mpz_t mpz_class::get_mpz_t () \[Function\] mpq_t mpq_class::get_mpq_t () \[Function\] mpf_t mpf_class::get_mpf_t () \[Function\]

These can be used to call a C function which doesn't have a C++ class interface. For example to set a to the GCD of b and c,

mpz_class a, b, c; ... mpz_gcd (a.get_mpz_t(), b.get_mpz_t(), c.get_mpz_t());

In the other direction, a class can be initialized from the corresponding GMP C type, or assigned to if an explicit constructor is used. In both cases this makes a copy of the value, it doesn't create any sort of association. For example,

mpz_t z;

// ... init and calculate z ...

mpz_class x(z); mpz_class y; y = mpz_class (z);

There are no namespace setups in gmpxx.h, all types and functions are simply put into the global namespace. This is what gmp.h has done in the past, and continues to do for compatibility. The extras provided by gmpxx.h follow GMP naming conventions and are unlikely to clash with anything.

## 12.2 C++ Interface Integers

mpz*class::mpz_class (\_type n*) \[Function\]

Construct an mpz*class. All the standard C++ types may be used, except longlong and longdouble, and all the GMP C++ classes can be used, although conversions from mpq* class and mpf_class are explicit. Any necessary conversion follows the corresponding C function, for example double follows mpz_set_d (see Section 5.2 \[Assigning Integers\], page 32).

explicit mpz*class::mpz_class (\_const mpz t z*) \[Function\]

Construct an mpz*class from an mpz_t. The value in \_z* is copied into the new mpz*class, there won't be any permanent association between it and \_z*.

explicit mpz*class::mpz_class (\_const char \*s, int base = 0*) \[Function\] explicit mpz*class::mpz_class (\_const string& s, int base = 0*) \[Function\] Construct an mpz_class converted from a string using mpz_set_str (see Section 5.2 \[Assigning Integers\], page 32).

If the string is not a valid integer, an std::invalid_argument exception is thrown. The same applies to operator=.

mpz*class operator"" \_mpz* (_const char \*str_)

With C++11 compilers, integers can be constructed with the syntax 123_mpz which is equivalent to mpz_class("123").

mpz*class operator/ (\_mpzclass a, mpzclass d*) \[Function\] mpz*class operator% (\_mpzclass a, mpzclass d*) \[Function\]

Divisions involving mpz_class round towards zero, as per the mpz_tdiv_q and mpz_tdiv_r functions (see Section 5.6 \[Integer Division\], page 34). This is the same as the C99 / and % operators.

The mpz_fdiv... or mpz_cdiv... functions can always be called directly if desired. For example,

mpz_class q, a, d; ... mpz_fdiv_q (q.get_mpz_t(), a.get_mpz_t(), d.get_mpz_t());

mpz*class abs (\_mpz class op*) \[Function\] int cmp (_mpz class op1, type op2_) \[Function\] int cmp (_type op1, mpz class op2_) \[Function\] bool mpz*class::fits_sint_p (\_void*) \[Function\] bool mpz*class::fits_slong_p (\_void*) \[Function\] bool mpz*class::fits_sshort_p (\_void*) \[Function\] bool mpz*class::fits_uint_p (\_void*) \[Function\] bool mpz*class::fits_ulong_p (\_void*) \[Function\] bool mpz*class::fits_ushort_p (\_void*) \[Function\] double mpz*class::get_d (\_void*) \[Function\] long mpz*class::get_si (\_void*) \[Function\] string mpz*class::get_str (\_int base = 10*) \[Function\] unsigned long mpz*class::get_ui (\_void*) \[Function\] int mpz*class::set_str (\_const char \*str, int base*) \[Function\] int mpz*class::set_str (\_const string& str, int base*) \[Function\] int sgn (_mpz class op_) \[Function\] mpz*class sqrt (\_mpz class op*) \[Function\] mpz*class gcd (\_mpz class op1, mpzclass op2*) \[Function\] mpz*class lcm (\_mpz class op1, mpzclass op2*) \[Function\] mpz*class mpz_class::factorial (\_type op*) \[Function\] mpz*class factorial (\_mpz class op*) \[Function\] mpz*class mpz_class::primorial (\_type op*) \[Function\] mpz*class primorial (\_mpz class op*) \[Function\] mpz*class mpz_class::fibonacci (\_type op*) \[Function\] mpz*class fibonacci (\_mpz class op*) \[Function\] void mpz*class::swap (\_mpz class& op*) \[Function\] void swap (_mpz class& op1, mpz class& op2_) \[Function\]

These functions provide a C++ class interface to the corresponding GMP C routines. Calling factorial or primorial on a negative number is undefined.

cmp can be used with any of the classes or the standard C++ types, except longlong and longdouble.

Overloaded operators for combinations of mpz_class and double are provided for completeness, but it should be noted that if the given double is not an integer then the way any rounding is done is currently unspecified. The rounding might take place at the start, in the middle, or at the end of the operation, and it might change in the future.

Conversions between mpz_class and double, however, are defined to follow the corresponding C functions mpz_get_d and mpz_set_d. And comparisons are always made exactly, as per mpz_cmp_d.

## 12.3 C++ Interface Rationals

In all the following constructors, if a fraction is given then it should be in canonical form, or if not then mpq_class::canonicalize called.

mpq*class::mpq_class (\_type op*) \[Function\] mpq*class::mpq_class (\_integer num, integer den*) \[Function\]

Construct an mpq_class. The initial value can be a single value of any type (conversion from mpf_class is explicit), or a pair of integers (mpz_class or standard C++ integer types) representing a fraction, except that longlong and longdouble are not supported. For example,

mpq_class q (99); mpq_class q (1.75); mpq_class q (1, 3);

explicit mpq*class::mpq_class (\_const mpq t q*) \[Function\]

Construct an mpq*class from an mpq_t. The value in \_q* is copied into the new mpq*class, there won't be any permanent association between it and \_q*.

explicit mpq*class::mpq_class (\_const char \*s, int base = 0*) \[Function\] explicit mpq*class::mpq_class (\_const string& s, int base = 0*) \[Function\]

Construct an mpq_class converted from a string using mpq_set_str (see Section 6.1 \[Initializing Rationals\], page 47).

If the string is not a valid rational, an std::invalid_argument exception is thrown. The same applies to operator=.

mpq*class operator"" \_mpq* (_const char \*str_) \[Function\]

With C++11 compilers, integral rationals can be constructed with the syntax 123_mpq which is equivalent to mpq_class(123_mpz). Other rationals can be built as -1_mpq/2 or 0xb_mpq/123456_mpz.

void mpq_class::canonicalize () \[Function\]

Put an mpq_class into canonical form, as per Chapter 6 \[Rational Number Functions\], page 47. All arithmetic operators require their operands in canonical form, and will return results in canonical form.

mpq*class abs (\_mpq class op*) \[Function\] int cmp (_mpq class op1, type op2_) \[Function\] int cmp (_type op1, mpq class op2_) \[Function\]

| double mpq*class::get_d (\_void*)                       | \[Function\] |
| ------------------------------------------------------- | ------------ |
| string mpq*class::get_str (\_int base = 10*)            | \[Function\] |
| int mpq*class::set_str (\_const char \*str, int base*)  | \[Function\] |
| int mpq*class::set_str (\_const string& str, int base*) | \[Function\] |
| int sgn (_mpq class op_)                                | \[Function\] |
| void mpq*class::swap (\_mpq class& op*)                 | \[Function\] |

void swap (_mpq class& op1, mpq class& op2_)

These functions provide a C++ class interface to the corresponding GMP C routines.

cmp can be used with any of the classes or the standard C++ types, except longlong and longdouble.

mpz_class& mpq_class::get_num () \[Function\] mpz_class& mpq_class::get_den () \[Function\]

Get a reference to an mpz_class which is the numerator or denominator of an mpq_class. This can be used both for read and write access. If the object returned is modified, it modifies the original mpq_class.

If direct manipulation might produce a non-canonical value, then mpq_class::canonicalize must be called before further operations.

mpz_t mpq_class::get_num_mpz_t () \[Function\] mpz_t mpq_class::get_den_mpz_t () \[Function\]

Get a reference to the underlying mpz_t numerator or denominator of an mpq_class. This can be passed to C functions expecting an mpz_t. Any modifications made to the mpz_t will modify the original mpq_class.

If direct manipulation might produce a non-canonical value, then mpq_class::canonicalize must be called before further operations.

istream& operator>> (_istream& stream, mpq class& rop_)_;_ \[Function\]

Read _rop_ from _stream_, using its ios formatting settings, the same as mpq_toperator>> (see Section 11.3 \[C++ Formatted Input\], page 81).

If the _rop_ read might not be in canonical form then mpq_class::canonicalize must be called.

## 12.4 C++ Interface Floats

When an expression requires the use of temporary intermediate mpf_class values, like f=g\*h+x\*y, those temporaries will have the same precision as the destination f. Explicit constructors can be used if this doesn't suit.

mpf*class::mpf_class (\_type op*) \[Function\] mpf*class::mpf_class (\_type op, mp bitcnt t prec*) \[Function\]

Construct an mpf_class. Any standard C++ type can be used, except longlong and long double, and any of the GMP C++ classes can be used.

If _prec_ is given, the initial precision is that value, in bits. If _prec_ is not given, then the initial precision is determined by the type of _op_ given. An mpz_class, mpq_class, or C++ builtin type will give the default mpf precision (see Section 7.1 \[Initializing Floats\], page 52). An mpf_class or expression will give the precision of that value. The precision of a binary expression is the higher of the two operands.

| mpf_class f(1.5);      | // default precision                |
| ---------------------- | ----------------------------------- |
| mpf_class f(1.5, 500); | // 500 bits (at least)              |
| mpf_class f(x);        | // precision of x                   |
| mpf_class f(abs(x));   | // precision of x                   |
| mpf_class f(-g, 1000); | // 1000 bits (at least)             |
| mpf_class f(x+y);      | // greater of precisions of x and y |

explicit mpf*class::mpf_class (\_const mpf t f*) mpf*class::mpf_class (\_const mpf t f, mp bitcnt t prec*)

Construct an mpf*class from an mpf_t. The value in \_f* is copied into the new mpf*class, there won't be any permanent association between it and \_f*.

If _prec_ is given, the initial precision is that value, in bits. If _prec_ is not given, then the initial precision is that of _f_.

explicit mpf*class::mpf_class (\_const char \*s*) \[Function\] mpf*class::mpf_class (\_const char \*s, mp bitcnt t prec, int base = 0*) \[Function\] explicit mpf*class::mpf_class (\_const string& s*) \[Function\] mpf*class::mpf_class (\_const string& s, mp bitcnt t prec, int base = 0*) \[Function\] Construct an mpf*class converted from a string using mpf_set_str (see Section 7.2 \[Assigning Floats\], page 54). If \_prec* is given, the initial precision is that value, in bits. If not, the default mpf precision (see Section 7.1 \[Initializing Floats\], page 52) is used.

If the string is not a valid float, an std::invalid_argument exception is thrown. The same applies to operator=.

mpf*class operator"" \_mpf* (_const char \*str_) \[Function\]

With C++11 compilers, floats can be constructed with the syntax 1.23e-1_mpf which is equivalent to mpf_class("1.23e-1").

mpf*class& mpf_class::operator= (\_type op*) \[Function\]

Convert and store the given _op_ value to an mpf_class object. The same types are accepted as for the constructors above.

Note that operator= only stores a new value, it doesn't copy or change the precision of the destination, instead the value is truncated if necessary. This is the same as mpf_set etc. Note in particular this means for mpf_class a copy constructor is not the same as a default constructor plus assignment.

mpf_class x (y); // x created with precision of y

mpf_class x; // x created with default precision x = y; // value truncated to that precision

Applications using templated code may need to be careful about the assumptions the code makes in this area, when working with mpf_class values of various different or non-default precisions. For instance implementations of the standard complex template have been seen in both styles above, though of course complex is normally only actually specified for use with the builtin float types.

mpf*class abs (\_mpf class op*) \[Function\] mpf*class ceil (\_mpf class op*) \[Function\] int cmp (_mpf class op1, type op2_) \[Function\] int cmp (_type op1, mpf class op2_) \[Function\]

| bool mpf*class::fits_sint_p (\_void*)             | \[Function\] |
| ------------------------------------------------- | ------------ |
| bool mpf*class::fits_slong_p (\_void*)            | \[Function\] |
| bool mpf*class::fits_sshort_p (\_void*)           | \[Function\] |
| bool mpf*class::fits_uint_p (\_void*)             | \[Function\] |
| bool mpf*class::fits_ulong_p (\_void*)            | \[Function\] |
| bool mpf*class::fits_ushort_p (\_void*)           | \[Function\] |
| mpf*class floor (\_mpf class op*)                 | \[Function\] |
| mpf*class hypot (\_mpf class op1, mpf class op2*) | \[Function\] |

double mpf*class::get_d (\_void*) long mpf*class::get_si (\_void*)

string mpf*class::get_str (\_mp exp t& exp, int base = 10, size t* \[Function\] _digits = 0_)

unsigned long mpf*class::get_ui (\_void*) \[Function\] int mpf*class::set_str (\_const char \*str, int base*) \[Function\] int mpf*class::set_str (\_const string& str, int base*) \[Function\] int sgn (_mpf class op_) \[Function\] mpf*class sqrt (\_mpf class op*) \[Function\] void mpf*class::swap (\_mpf class& op*) \[Function\] void swap (_mpf class& op1, mpf class& op2_) \[Function\] mpf*class trunc (\_mpf class op*) \[Function\]

These functions provide a C++ class interface to the corresponding GMP C routines.

cmp can be used with any of the classes or the standard C++ types, except longlong and longdouble.

The accuracy provided by hypot is not currently guaranteed.

mp*bitcnt_t mpf_class::get_prec () \[Function\] void mpf_class::set_prec (\_mp bitcnt t prec*) \[Function\] void mpf*class::set_prec_raw (\_mp bitcnt t prec*) \[Function\]

Get or set the current precision of an mpf_class.

The restrictions described for mpf_set_prec_raw (see Section 7.1 \[Initializing Floats\], page 52) apply to mpf_class::set_prec_raw. Note in particular that the mpf_class must be restored to its allocated precision before being destroyed. This must be done by application code, there's no automatic mechanism for it.

## 12.5 C++ Interface Random Numbers

gmp_randclass \[Class\]

The C++ class interface to the GMP random number functions uses gmp_randclass to hold an algorithm selection and current state, as per gmp_randstate_t.

gmp*randclass::gmp_randclass (\_void* (_\*randinit_) (_gmp randstate t,_ \[Function\]

_. . ._)_, . . ._)

Construct a gmp*randclass, using a call to the given \_randinit* function (see Section 9.1 \[Random State Initialization\], page 72). The arguments expected are the same as _randinit_, but with mpz_class instead of mpz_t. For example,

gmp_randclass r1 (gmp_randinit_default); gmp_randclass r2 (gmp_randinit_lc_2exp_size, 32); gmp_randclass r3 (gmp_randinit_lc_2exp, a, c, m2exp); gmp_randclass r4 (gmp_randinit_mt);

gmp_randinit_lc_2exp_size will fail if the size requested is too big, an std::length_error exception is thrown in that case.

gmp*randclass::gmp_randclass (\_gmp randalg t alg, . . .*) \[Function\]

Construct a gmp*randclass using the same parameters as gmp_randinit (see Section 9.1 \[Random State Initialization\], page 72). This function is obsolete and the above \_randinit* style should be preferred.

void gmp*randclass::seed (\_unsigned long int s*) void gmp*randclass::seed (\_mpz class s*)

Seed a random number generator. See see Chapter 9 \[Random Number Functions\], page 72, for how to choose a good seed.

mpz*class gmp_randclass::get_z_bits (\_mp bitcnt t bits*) \[Function\] mpz*class gmp_randclass::get_z_bits (\_mpz class bits*) \[Function\]

Generate a random integer with a specified number of bits.

mpz*class gmp_randclass::get_z_range (\_mpz class n*) \[Function\]

Generate a random integer in the range 0 to _n_ − 1 inclusive.

mpf*class gmp_randclass::get_f () \[Function\] mpf_class gmp_randclass::get_f (\_mp bitcnt t prec*) \[Function\]

Generate a random float _f_ in the range 0 _<_\= _f <_ 1\. _f_ will be to _prec_ bits precision, or if _prec_ is not given then to the precision of the destination. For example,

gmp_randclass r; ...

mpf_class f (0, 512); // 512 bits precision f = r.get_f(); // random number, 512 bits

## 12.6 C++ Interface Limitations

mpq_class and Templated Reading

A generic piece of template code probably won't know that mpq_class requires a canonicalize call if inputs read with operator>> might be non-canonical. This can lead to incorrect results.

operator>> behaves as it does for reasons of efficiency. A canonicalize can be quite time consuming on large operands, and is best avoided if it's not necessary.

But this potential difficulty reduces the usefulness of mpq_class. Perhaps a mechanism to tell operator>> what to do will be adopted in the future, maybe a preprocessor define, a global flag, or an ios flag pressed into service. Or maybe, at the risk of inconsistency, the mpq_class operator>> could canonicalize and leave mpq_toperator>> not doing so, for use on those occasions when that's acceptable. Send feedback or alternate ideas to <gmp-bugs@gmplib.org>.

Subclassing

Subclassing the GMP C++ classes works, but is not currently recommended.

Expressions involving subclasses resolve correctly (or seem to), but in normal C++ fashion the subclass doesn't inherit constructors and assignments. There's many of those in the GMP classes, and a good way to reestablish them in a subclass is not yet provided.

Templated Expressions

A subtle difficulty exists when using expressions together with application-defined template functions. Consider the following, with T intended to be some numeric type,

template &lt;class T&gt;

T fun (const T &, const T &);

When used with, say, plain mpz_class variables, it works fine: T is resolved as mpz_class.

mpz_class f(1), g(2);

fun (f, g); // Good

But when one of the arguments is an expression, it doesn't work.

mpz_class f(1), g(2), h(3); fun (f, g+h); // Bad

This is because g+h ends up being a certain expression template type internal to gmpxx.h, which the C++ template resolution rules are unable to automatically convert to mpz_class. The workaround is simply to add an explicit cast.

mpz_class f(1), g(2), h(3); fun (f, mpz_class(g+h)); // Good

Similarly, within fun it may be necessary to cast an expression to type T when calling a templated fun2. template &lt;class T&gt; void fun (T f, T g)

{

fun2 (f, f+g); // Bad

}

template &lt;class T&gt; void fun (T f, T g)

{ fun2 (f, T(f+g)); // Good

}

C++11 C++11 provides several new ways in which types can be inferred: auto, decltype, etc. While they can be very convenient, they don't mix well with expression templates. In this example, the addition is performed twice, as if we had defined sum as a macro.

mpz_class z = 33; auto sum = z + z; mpz_class prod = sum \* sum;

This other example may crash, though some compilers might make it look like it is working, because the expression z+z goes out of scope before it is evaluated.

mpz_class z = 33; auto sum = z + z + z; mpz_class prod = sum \* 2;

It is thus strongly recommended to avoid auto anywhere a GMP C++ expression may appear.

# 13 Custom Allocation

By default GMP uses malloc, realloc and free for memory allocation, and if they fail GMP prints a message to the standard error output and terminates the program.

Alternate functions can be specified, to allocate memory in a different way or to have a different error action on running out of memory.

void mp_set_memory_functions ( \[Function\]

_void \*_(_\*alloc_func_ptr_) (_size t_)_, void \*_(_\*realloc_func_ptr_) (_void \*, size t, size t_)_, void_ (_\*free_func_ptr_) (_void \*, size t_))

Replace the current allocation functions from the arguments. If an argument is NULL, the corresponding default function is used.

These functions will be used for all memory allocation done by GMP, apart from temporary space from alloca if that function is available and GMP is configured to use it (see Section 2.1 \[Build Options\], page 3).

Be sure to call mp_set_memory_functions only when there are no active GMP objects allocated using the previous memory functions! Usually that means calling it before any other GMP function.

The functions supplied should fit the following declarations:

void \* allocate*function (\_size t alloc_size*) \[Function\]

Return a pointer to newly allocated space with at least _alloc size_ bytes.

void \* reallocate*function (\_void \*ptr, size t old_size, sizet* \[Function\] _new_size_)

Resize a previously allocated block _ptr_ of _old size_ bytes to be _newsize_ bytes.

The block may be moved if necessary or if desired, and in that case the smaller of _old size_ and _new size_ bytes must be copied to the new location. The return value is a pointer to the resized block, that being the new location if moved or just _ptr_ if not.

_ptr_ is never NULL, it's always a previously allocated block. _new size_ may be bigger or smaller than _old size_.

void free*function (\_void \*ptr, size t size*) \[Function\]

De-allocate the space pointed to by _ptr_. _ptr_ is never NULL, it's always a previously allocated block of _size_ bytes.

A _byte_ here means the unit used by the sizeof operator.

The _reallocate function_ parameter _old size_ and the _free function_ parameter _size_ are passed for convenience, but of course they can be ignored if not needed by an implementation. The default functions using malloc and friends for instance don't use them.

No error return is allowed from any of these functions, if they return then they must have performed the specified operation. In particular note that _allocate function_ or _reallocate function_ mustn't return NULL.

Chapter 13: Custom Allocation

Getting a different fatal error action is a good use for custom allocation functions, for example giving a graphical dialog rather than the default print to stderr. How much is possible when genuinely out of memory is another question though.

There's currently no defined way for the allocation functions to recover from an error such as out of memory, they must terminate program execution. A longjmp or throwing a C++ exception will have undefined results. This may change in the future.

GMP may use allocated blocks to hold pointers to other allocated blocks. This will limit the assumptions a conservative garbage collection scheme can make.

Since the default GMP allocation uses malloc and friends, those functions will be linked in even if the first thing a program does is an mp_set_memory_functions. It's necessary to change the GMP sources if this is a problem.

void mp_get_memory_functions ( \[Function\]

_void \*_(_\*\*alloc_func_ptr_) (_size t_)_, void \*_(_\*\*realloc_func_ptr_) (_void \*, size t, size t_)_, void_ (_\*\*free_func_ptr_) (_void \*, size t_))

Get the current allocation functions, storing function pointers to the locations given by the arguments. If an argument is NULL, that function pointer is not stored.

For example, to get just the current free function, void (\*freefunc) (void \*, size_t); mp_get_memory_functions (NULL, NULL, &freefunc);

# 14 Language Bindings

The following packages and projects offer access to GMP from languages other than C, though perhaps with varying levels of functionality and efficiency.

C++

- GMP C++ class interface, see Chapter 12 \[C++ Class Interface\], page 83 Straightforward interface, expression templates to eliminate temporaries.
- ALP <https://www-sop.inria.fr/saga/logiciels/ALP/> Linear algebra and polynomials using templates.
- CLN <https://www.ginac.de/CLN/>

High level classes for arithmetic.

- Linbox <http://www.linalg.org/> Sparse vectors and matrices.
- NTL <http://www.shoup.net/ntl/> A C++ number theory library.

Eiffel

- Eiffelroom <http://www.eiffelroom.org/node/442>

Haskell

- Glasgow Haskell Compiler <https://www.haskell.org/ghc/>

Java

- Kaffe <https://github.com/kaffe/kaffe>

Lisp

- GNU Common Lisp <https://www.gnu.org/software/gcl/gcl.html>
- Librep <http://librep.sourceforge.net/>
- XEmacs (21.5.18 beta and up) [https://www.xemacs.org](https://www.xemacs.org/) Optional big integers, rationals and floats using GMP.

ML

- MLton compiler <http://mlton.org/>

Objective Caml

- MLGMP <https://opam.ocaml.org/packages/mlgmp/>
- Numerix <http://pauillac.inria.fr/~quercia/> Optionally using GMP.

Oz

- Mozart <https://mozart.github.io/>

Pascal

- GNU Pascal Compiler <http://www.gnu-pascal.de/> GMP unit.
- Numerix <http://pauillac.inria.fr/~quercia/> For Free Pascal, optionally using GMP.

Perl

- GMP module, see demos/perl in the GMP sources (see Section 3.10 \[Demonstration Programs\], page 22).

Chapter 14: Language Bindings

- Math::GMP <https://www.cpan.org/>

Compatible with Math::BigInt, but not as many functions as the GMP module above.

- Math::BigInt::GMP <https://www.cpan.org/> Plug Math::GMP into normal Math::BigInt operations.

Pike

- pikempz module in the standard distribution, [https://pike.lysator.liu. se/](https://pike.lysator.liu.se/) Prolog
- SWI Prolog <http://www.swi-prolog.org/>

Arbitrary precision floats.

Python

- GMPY <https://code.google.com/p/gmpy/> Ruby
- <https://rubygems.org/gems/gmp> Scheme
- GNU Guile <https://www.gnu.org/software/guile/guile.html>
- RScheme <https://www.rscheme.org/>
- STklos <http://www.stklos.net/>

Smalltalk

- GNU Smalltalk <http://smalltalk.gnu.org/>

Other

- Axiom <https://savannah.nongnu.org/projects/axiom> Computer algebra using GCL.
- DrGenius <http://drgenius.seul.org/>

Geometry system and mathematical programming language.

- GiNaC [httsp://www.ginac.de/](httsp://www.ginac.de/) C++ computer algebra using CLN.
- GOO <https://www.eecs.berkeley.edu/~jrb/goo/> Dynamic object oriented language.
- Maxima <https://www.ma.utexas.edu/users/wfs/maxima.html> Macsyma computer algebra using GCL.
- Regina <http://regina.sourceforge.net/>

Topological calculator.

- Yacas [http://yacas.sourceforge.net](http://yacas.sourceforge.net/) Yet another computer algebra system.

# 15 Algorithms

This chapter is an introduction to some of the algorithms used for various GMP operations. The code is likely to be hard to understand without knowing something about the algorithms.

Some GMP internals are mentioned, but applications that expect to be compatible with future GMP releases should take care to use only the documented functions.

## 15.1 Multiplication

N×N limb multiplications and squares are done using one of seven algorithms, as the size N increases.

| Algorithm | Threshold            |
| --------- | -------------------- |
| Basecase  | (none)               |
| Karatsuba | MUL_TOOM22_THRESHOLD |
| Toom-3    | MUL_TOOM33_THRESHOLD |
| Toom-4    | MUL_TOOM44_THRESHOLD |
| Toom-6.5  | MUL_TOOM6H_THRESHOLD |
| Toom-8.5  | MUL_TOOM8H_THRESHOLD |
| FFT       | MUL_FFT_THRESHOLD    |

Similarly for squaring, with the SQR thresholds.

N×M multiplications of operands with different sizes above MUL_TOOM22_THRESHOLD are currently done by special Toom-inspired algorithms or directly with FFT, depending on operand size (see Section 15.1.8 \[Unbalanced Multiplication\], page 102).

### 15.1.1 Basecase Multiplication

Basecase N×M multiplication is a straightforward rectangular set of cross-products, the same as long multiplication done by hand and for that reason sometimes known as the schoolbook or grammar school method. This is an _O_(_NM_) algorithm. See Knuth section 4.3.1 algorithm M (see Appendix B \[References\], page 130), and the mpn/generic/mul_basecase.c code.

Assembly implementations of mpn_mul_basecase are essentially the same as the generic C code, but have all the usual assembly tricks and obscurities introduced for speed.

A square can be done in roughly half the time of a multiply, by using the fact that the cross products above and below the diagonal are the same. A triangle of products below the diagonal is formed, doubled (left shift by one bit), and then the products on the diagonal added. This can be seen in mpn/generic/sqr_basecase.c. Again the assembly implementations take essentially the same approach.

u0

u1

u2

u3

u4

u2

u4

u3

u1

u0

d

d

d

d

d

In practice squaring isn't a full 2× faster than multiplying, it's usually around 1.5×. Less than

1.5× probably indicates mpn_sqr_basecase wants improving on that CPU.

On some CPUs mpn_mul_basecase can be faster than the generic C mpn_sqr_basecase on some small sizes. SQR_BASECASE_THRESHOLD is the size at which to use mpn_sqr_basecase, this will be zero if that routine should be used always.

### 15.1.2 Karatsuba Multiplication

The Karatsuba multiplication algorithm is described in Knuth section 4.3.3 part A, and various other textbooks. A brief description is given here.

The inputs _x_ and _y_ are treated as each split into two parts of equal length (or the most significant part one limb shorter if N is odd).

high low

| _x_<sub>1</sub> | _x_<sub>0</sub> |
| --------------- | --------------- |
|                 |                 |
| _y_<sub>1</sub> | _y_<sub>0</sub> |

Let _b_ be the power of 2 where the split occurs, i.e. if _x_<sub>0</sub> is _k_ limbs (_y_<sub>0</sub> the same) then _b_ \=

2*<sup>k</sup>*<sup>∗mp bits per limb</sup>. With that _x_ \= _x_<sub>1</sub>_b_ \+ _x_<sub>0</sub> and _y_ \= _y_<sub>1</sub>_b_ \+ _y_<sub>0</sub>, and the following holds, _xy_ \= (_b_<sup>2</sup> \+ _b_)_x_<sub>1</sub>_y_<sub>1</sub> − _b_(_x_<sub>1</sub> − _x_<sub>0</sub>)(_y_<sub>1</sub> − _y_<sub>0</sub>) + (_b_ \+ 1)_x_<sub>0</sub>_y_<sub>0</sub>

This formula means doing only three multiplies of (N/2)×(N/2) limbs, whereas a basecase multiply of N×N limbs is equivalent to four multiplies of (N/2)×(N/2). The factors (_b_<sup>2</sup> +_b_) etc represent the positions where the three products must be added.

high low

| \_x_1_y_1 | \_x_0_y_0 |
| --------- | --------- |

\_x_1_y_1

-

\_x_0_y_0

-

(_x_<sub>1</sub> − _x_<sub>0</sub>)(_y_<sub>1</sub> − _y_<sub>0</sub>)

−

The term (_x_<sub>1</sub> −*x*<sub>0</sub>)(_y_<sub>1</sub> −*y*<sub>0</sub>) is best calculated as an absolute value, and the sign used to choose to add or subtract. Notice the sum high(_x_<sub>0</sub>_y_<sub>0</sub>)+low(_x_<sub>1</sub>_y_<sub>1</sub>) occurs twice, so it's possible to do 5*k* limb additions, rather than 6*k*, but in GMP extra function call overheads outweigh the saving.

Squaring is similar to multiplying, but with _x_ \= _y_ the formula reduces to an equivalent with three squares,

![](data:image/png;base64,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)

The final result is accumulated from those three squares the same way as for the three multiplies above. The middle term (_x_<sub>1</sub> − _x_<sub>0</sub>)<sup>2</sup> is now always positive.

A similar formula for both multiplying and squaring can be constructed with a middle term (_x_<sub>1</sub> \+ _x_<sub>0</sub>)(_y_<sub>1</sub> \+ _y_<sub>0</sub>). But those sums can exceed _k_ limbs, leading to more carry handling and additions than the form above.

Karatsuba multiplication is asymptotically an _O_(_N_<sup>1</sup>_<sup>.</sup>_<sup>585</sup>) algorithm, the exponent being log3*/\_log2, representing 3 multiplies each 1*/_2 the size of the inputs. This is a big improvement over the basecase multiply at \_O_(_N_<sup>2</sup>) and the advantage soon overcomes the extra additions Karatsuba performs. MUL_TOOM22_THRESHOLD can be as little as 10 limbs. The SQR threshold is usually about twice the MUL.

The basecase algorithm will take a time of the form _M_(_N_) = _aN_<sup>2</sup> \+ _bN_ \+ _c_ and the Karatsuba algorithm _K_(_N_) = 3*M*(_N/\_2)+\_dN_+_e_, which expands to![](data:image/png;base64,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). The factor ![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABIAAAA2CAYAAADK88l3AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAAAHSSURBVFhH7ZchTwMxGIYf4AcAOYEhiIFBXUIIgpxGzI6ECQTuBJqZIRBMowYGgSLTqIFAEQQEQYIcCILlDD9gmHb59q13124kCHiSy3Xf271t72t7PfghpnRAUAG2gTVgzsRugXvgTtXNpQX0gBRITCwBOkAf6JqGCmkBj0CkBUPXmBXVASATrbqoG71vygBMD9cZYkUHDB+ivGQLLqNd4AyoacGwKcovohyMfUY9LYRgn08GxFr0IQYaIgnBJqfmj3I4g0xNQioMg3ulsWZ9MevHIhJGE2UO8cwGvdIT0mamdB0JFnUAsc7Kxj/SI43vyrYmmRYsVQ8TmbWqFiV101Lq2LysSeY7MStig7NDtfeGo4F/foMjMTfGuvRa++dPMaMDHlSBBeBdCyEkZgI2tBAyISPgQgctIUZtYFkHLb5Gdlu9VvEBPkYxcAzsa0HiY3QO7AGfWpCUGbWAG59zdZFRAmwBTS24yDOyqd7RQh55Rm3gEHjTQh4uo9TcOypeiDaKgYOyVLuQRpFJda0s1S7kZ1YCXAEPIqbZAOaBV3HsewKa0igCVsVvFyfAuvnEuDSxL+BZ1SvFHsQm2kYkszoQQizOmL1xzkgjr2d1dQG+AfRYgVjY8faoAAAAAElFTkSuQmCC) for _a_ means per-crossproduct speedups in the basecase code will increase the threshold since they benefit _M_(_N_) more than _K_(_N_). And conversely the ![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABIAAAA3CAYAAAABrxrSAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAAAIaSURBVFhH7Ze/axVBEMc/mj9A8DVWQR6CNnKCkOr+gMTKSqxsg/4BL/kHLNT+wDaFKPgHmCqN2ByIViJE8Udj45OQwvJsvvOcG3fvbkMaIR84bm9nd97u7MzsPDglzsWOBLXex8D7IBulBl4Bh8Bz4CHQAh3QAPM4IcVdTbKVRFkHLDPyFTMNbIEqCoWtbBkFnlqDOm0pxcKNWa3qfH8MH4Bfau8FmXHZtY9dO8mQMW1rh1FQgt/6rSicSiUDdzq9ycxk2IV8qtM7ue212OH4Lc//DrwDvgK3gRvAF+BbnFCC394iCkvZPg2DIxuZoqwL1FpyLjwMU9TpUHpYnHVjcZRS5EPkgmsP4Y//E/DTfa+w/DO0NUslnQyfpJKy3Gn442+8IJVqK+ARcAV4Icc7Aq4D96XoCfDUT0opMubABrDu+t4Ar933GQWYsTeBS0FWwg9rHAS3L30ObEW7wNW/P1DMx9hxxv/AUPTXwBZwU9+fVbG9zGXFyEw3aquLoFZWbJwDTrrTWpV6KXya7WXIyLZWM4QvtHIpuVcs5PAXZK6q6wVisuoQNqa1jlj67ei9r1MaY9Lp5ahSBo8rmsId137m2kXM3QWZc5FRZuFvxIkxzz7xSpCSZWk1G2lUWAxVKKM0sss/VZkMP+n4bdBmxvGuARftI6fIlDzIKAG4B7yNnYblIh9zQ89o9E99Vv/XYqqdlPkcj63xBx2Fr7uKt9EwAAAAAElFTkSuQmCC) for _b_ means linear style speedups of _b_ will increase the threshold since they benefit _K_(_N_) more than _M_(_N_). The latter can be seen for instance when adding an optimized mpn_sqr_diagonal to mpn_sqr_basecase. Of course all speedups reduce total time, and in that sense the algorithm thresholds are merely of academic interest.

### 15.1.3 Toom 3-Way Multiplication

The Karatsuba formula is the simplest case of a general approach to splitting inputs that leads to both Toom and FFT algorithms. A description of Toom can be found in Knuth section 4.3.3, with an example 3-way calculation after Theorem A. The 3-way form used in GMP is described here.

The operands are each considered split into 3 pieces of equal length (or the most significant part 1 or 2 limbs shorter than the other two).

high low

| _x_<sub>2</sub> | _x_<sub>1</sub> | _x_<sub>0</sub> |
| --------------- | --------------- | --------------- |
|                 |                 |                 |
| _y_<sub>2</sub> | _y_<sub>1</sub> | _y_<sub>0</sub> |

These parts are treated as the coefficients of two polynomials

_X_(_t_) = _x_<sub>2</sub>_t_<sup>2</sup> \+ _x_<sub>1</sub>_t_ \+ _x_<sub>0</sub> _Y_ (_t_) = _y_<sub>2</sub>_t_<sup>2</sup> \+ _y_<sub>1</sub>_t_ \+ _y_<sub>0</sub>

Let _b_ equal the power of 2 which is the size of the _x_<sub>0</sub>, _x_<sub>1</sub>, _y_<sub>0</sub> and _y_<sub>1</sub> pieces, i.e. if they're _k_ limbs each then _b_ \= 2*<sup>k</sup>*<sup>∗mp bits per limb</sup>. With this _x_ \= _X_(_b_) and _y_ \= _Y_ (_b_).

Let a polynomial _W_(_t_) = _X_(_t_)_Y_ (_t_) and suppose its coefficients are

_W_(_t_) = _w_<sub>4</sub>_t_<sup>4</sup> \+ _w_<sub>3</sub>_t_<sup>3</sup> \+ _w_<sub>2</sub>_t_<sup>2</sup> \+ _w_<sub>1</sub>_t_ \+ _w_<sub>0</sub>

The _w<sub>i</sub>_ are going to be determined, and when they are they'll give the final result using _w_ \= _W_(_b_), since _xy_ \= _X_(_b_)_Y_ (_b_). The coefficients will be roughly _b_<sup>2</sup> each, and the final _W_(_b_) will be an addition like this:

high low

_w_<sub>4</sub>

_w_<sub>3</sub>

_w_<sub>2</sub>

_w_<sub>1</sub>

_w_<sub>0</sub>

The _w<sub>i</sub>_ coefficients could be formed by a simple set of cross products, like _w_<sub>4</sub> \= _x_<sub>2</sub>_y_<sub>2</sub>, _w_<sub>3</sub> \= _x_<sub>2</sub>_y_<sub>1</sub> \+ _x_<sub>1</sub>_y_<sub>2</sub>, _w_<sub>2</sub> \= _x_<sub>2</sub>_y_<sub>0</sub> \+ _x_<sub>1</sub>_y_<sub>1</sub> \+ _x_<sub>0</sub>_y_<sub>2</sub> etc, but this would need all nine _x<sub>i</sub>y<sub>j</sub>_ for _i,j_ \= 0*,\_1*,\_2, and would be equivalent merely to a basecase multiply. Instead the following approach is used.

_X_(_t_) and _Y_ (_t_) are evaluated and multiplied at 5 points, giving values of _W_(_t_) at those points. In GMP the following points are used:

Point Value

_t_ \= 0 _x_<sub>0</sub>_y_<sub>0</sub>, which gives _w_<sub>0</sub> immediately _t_ \= 1 (_x_<sub>2</sub> \+ _x_<sub>1</sub> \+ _x_<sub>0</sub>)(_y_<sub>2</sub> \+ _y_<sub>1</sub> \+ _y_<sub>0</sub>)

| _t_ \= −1 | (_x_<sub>2</sub> − _x_<sub>1</sub> \+ _x_<sub>0</sub>)(_y_<sub>2</sub> − _y_<sub>1</sub> \+ _y_<sub>0</sub>)       |
| --------- | ------------------------------------------------------------------------------------------------------------------ |
| _t_ \= 2  | (4*x*<sub>2</sub> \+ 2*x*<sub>1</sub> \+ _x_<sub>0</sub>)(4*y*<sub>2</sub> \+ 2*y*<sub>1</sub> \+ _y_<sub>0</sub>) |
| _t_ \= ∞  | _x_<sub>2</sub>_y_<sub>2</sub>, which gives _w_<sub>4</sub> immediately                                            |

At _t_ \= −1 the values can be negative and that's handled using the absolute values and tracking the sign separately. At _t_ \= ∞ the value is actually lim![](data:image/png;base64,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), but it's much easier to think of as simply _x_<sub>2</sub>_y_<sub>2</sub> giving _w_<sub>4</sub> immediately (much like _x_<sub>0</sub>_y_<sub>0</sub> at _t_ \= 0 gives _w_<sub>0</sub> immediately).

Each of the points substituted into _W_(_t_) = _w_<sub>4</sub>_t_<sup>4</sup> \+ ··· + _w_<sub>0</sub> gives a linear combination of the _w<sub>i</sub>_ coefficients, and the value of those combinations has just been calculated.

| _W_(0)  | \=  |                   |     |                  |     |                  |     |                  |     | _w_<sub>0</sub> |
| ------- | --- | ----------------- | --- | ---------------- | --- | ---------------- | --- | ---------------- | --- | --------------- |
| _W_(1)  | \=  | _w_<sub>4</sub>   | +   | _w_<sub>3</sub>  | +   | _w_<sub>2</sub>  | +   | _w_<sub>1</sub>  | +   | _w_<sub>0</sub> |
| _W_(−1) | \=  | _w_<sub>4</sub>   | −   | _w_<sub>3</sub>  | +   | _w_<sub>2</sub>  | −   | _w_<sub>1</sub>  | +   | _w_<sub>0</sub> |
| _W_(2)  | \=  | 16*w*<sub>4</sub> | +   | 8*w*<sub>3</sub> | +   | 4*w*<sub>2</sub> | +   | 2*w*<sub>1</sub> | +   | _w_<sub>0</sub> |
| _W_(∞)  | \=  | _w_<sub>4</sub>   |     |                  |     |                  |     |                  |     |                 |

This is a set of five equations in five unknowns, and some elementary linear algebra quickly isolates each _w<sub>i</sub>_. This involves adding or subtracting one _W_(_t_) value from another, and a couple of divisions by powers of 2 and one division by 3, the latter using the special mpn_divexact_by3 (see Section 15.2.5 \[Exact Division\], page 104).

The conversion of _W_(_t_) values to the coefficients is interpolation. A polynomial of degree 4 like _W_(_t_) is uniquely determined by values known at 5 different points. The points are arbitrary and can be chosen to make the linear equations come out with a convenient set of steps for quickly isolating the _w<sub>i</sub>_.

Squaring follows the same procedure as multiplication, but there's only one _X_(_t_) and it's evaluated at the 5 points, and those values squared to give values of _W_(_t_). The interpolation is then identical, and in fact the same toom_interpolate_5pts subroutine is used for both squaring and multiplying.

Toom-3 is asymptotically _O_(_N_<sup>1</sup>_<sup>.</sup>_<sup>465</sup>), the exponent being log5*/\_log3, representing 5 recursive multiplies of 1/3 the original size each. This is an improvement over Karatsuba at \_O*(_N_<sup>1</sup>_<sup>.</sup>_<sup>585</sup>), though Toom does more work in the evaluation and interpolation and so it only realizes its advantage above a certain size.

Near the crossover between Toom-3 and Karatsuba there's generally a range of sizes where the difference between the two is small. MUL_TOOM33_THRESHOLD is a somewhat arbitrary point in that range and successive runs of the tune program can give different values due to small variations in measuring. A graph of time versus size for the two shows the effect, see tune/README.

At the fairly small sizes where the Toom-3 thresholds occur it's worth remembering that the asymptotic behaviour for Karatsuba and Toom-3 can't be expected to make accurate predictions, due of course to the big influence of all sorts of overheads, and the fact that only a few recursions of each are being performed. Even at large sizes there's a good chance machine dependent effects like cache architecture will mean actual performance deviates from what might be predicted.

The formula given for the Karatsuba algorithm (see Section 15.1.2 \[Karatsuba Multiplication\], page 97) has an equivalent for Toom-3 involving only five multiplies, but this would be complicated and unenlightening.

An alternate view of Toom-3 can be found in Zuras (see Appendix B \[References\], page 130), using a vector to represent the _x_ and _y_ splits and a matrix multiplication for the evaluation and interpolation stages. The matrix inverses are not meant to be actually used, and they have elements with values much greater than in fact arise in the interpolation steps. The diagram shown for the 3-way is attractive, but again doesn't have to be implemented that way and for example with a bit of rearrangement just one division by 6 can be done.

### 15.1.4 Toom 4-Way Multiplication

Karatsuba and Toom-3 split the operands into 2 and 3 coefficients, respectively. Toom-4 analogously splits the operands into 4 coefficients. Using the notation from the section on Toom-3 multiplication, we form two polynomials:

_X_(_t_) = _x_<sub>3</sub>_t_<sup>3</sup> \+ _x_<sub>2</sub>_t_<sup>2</sup> \+ _x_<sub>1</sub>_t_ \+ _x_<sub>0</sub> _Y_ (_t_) = _y_<sub>3</sub>_t_<sup>3</sup> \+ _y_<sub>2</sub>_t_<sup>2</sup> \+ _y_<sub>1</sub>_t_ \+ _y_<sub>0</sub>

_X_(_t_) and _Y_ (_t_) are evaluated and multiplied at 7 points, giving values of _W_(_t_) at those points. In GMP the following points are used,

| Point          | Value                                                                                                                                                      |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| _t_ \= 0       | _x_<sub>0</sub>_y_<sub>0</sub>, which gives _w_<sub>0</sub> immediately                                                                                    |
| _t_ \= 1\_/_2  | (_x_<sub>3</sub> \+ 2*x*<sub>2</sub> \+ 4*x*<sub>1</sub> \+ 8*x*<sub>0</sub>)(_y_<sub>3</sub> \+ 2*y*<sub>2</sub> \+ 4*y*<sub>1</sub> \+ 8*y*<sub>0</sub>) |
| _t_ \= −1\_/_2 | (−*x*<sub>3</sub> \+ 2*x*<sub>2</sub> − 4*x*<sub>1</sub> \+ 8*x*<sub>0</sub>)(−*y*<sub>3</sub> \+ 2*y*<sub>2</sub> − 4*y*<sub>1</sub> \+ 8*y*<sub>0</sub>) |
| _t_ \= 1       | (_x_<sub>3</sub> \+ _x_<sub>2</sub> \+ _x_<sub>1</sub> \+ _x_<sub>0</sub>)(_y_<sub>3</sub> \+ _y_<sub>2</sub> \+ _y_<sub>1</sub> \+ _y_<sub>0</sub>)       |
| _t_ \= −1      | (−*x*<sub>3</sub> \+ _x_<sub>2</sub> − _x_<sub>1</sub> \+ _x_<sub>0</sub>)(−*y*<sub>3</sub> \+ _y_<sub>2</sub> − _y_<sub>1</sub> \+ _y_<sub>0</sub>)       |
| _t_ \= 2       | (8*x*<sub>3</sub> \+ 4*x*<sub>2</sub> \+ 2*x*<sub>1</sub> \+ _x_<sub>0</sub>)(8*y*<sub>3</sub> \+ 4*y*<sub>2</sub> \+ 2*y*<sub>1</sub> \+ _y_<sub>0</sub>) |
| _t_ \= ∞       | _x_<sub>3</sub>_y_<sub>3</sub>, which gives _w_<sub>6</sub> immediately                                                                                    |

The number of additions and subtractions for Toom-4 is much larger than for Toom-3. But several subexpressions occur multiple times, for example _x_<sub>2</sub> \+ _x_<sub>0</sub> occurs for both _t_ \= 1 and _t_ \= −1.

Toom-4 is asymptotically _O_(_N_<sup>1</sup>_<sup>.</sup>_<sup>404</sup>), the exponent being log7\_/_log4, representing 7 recursive multiplies of 1/4 the original size each.

### 15.1.5 Higher degree Toom'n'half

The Toom algorithms described above (see Section 15.1.3 \[Toom 3-Way Multiplication\], page 98, see Section 15.1.4 \[Toom 4-Way Multiplication\], page 100) generalize to split into an arbitrary number of pieces. In general a split of two equally long operands into _r_ pieces leads to evaluations and pointwise multiplications done at 2*r* − 1 points. To fully exploit symmetries it would be better to have a multiple of 4 points, that's why for higher degree Toom'n'half is used.

Toom'n'half means that the existence of one more piece is considered for a single operand. It can be virtual, i.e. zero, or real, when the two operands are not exactly balanced. By choosing an even _r_, Toom-![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACsAAAA3CAYAAACVSbMgAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAAAJRSURBVGhD7Zi/itRQFIc/7S0kvYjYD4gg7GYbK0m9YB5A2DeYN8gLWExhs7DVFrYLu42VlQGfIO4T6OgbjM05w+FsbpIZc5Mr5IPAzTk3mR9n7p/fDSwczcoHUiQDKmAH5D6pPPKBiXgBnEv7FfDe5M6Ar+Z+z2MfmIgnwHNpX4nA/4ZchkDnMJirskexiI3FIjYWi9hYLGJjsYiNxSI2Fl5sBmyAGrgF1hLzfS4k39VvKBlwYu5PxO/2UovYlQjYSUyF5MBW+uTy0gJopN9QrCXsu1ot41qqZNEH1iJq685JK4l1vjgGTcuPqYimRSjA9ZAqjI3+lZbMCVm7PE7s9h/G7UFUMg4thatsGyt5bjN0UoxBDZQupkfjncz+2dGj+AXwGfhlcjXwWtrB4/EB5MBLHxwDP17H4NK98+Ar9JGjAG6kfQe8c/lj+ACc+uAY2PHatgokRW3ETrJ2HkuM8ToK3sgAvDHtO9OenTaxdhJ8Me0kSXa8+qUrA36ae58fG/1O+1bu/wDfZYO6d30fYP2At4tjU4nnqOR3C2mr5bzuM0ZTra+VFKNNjPXI1vg/wFq+WC5KxQRFuJNE5ZNKJhX1JntM9LjU9BSkkX5bn5iSW1M1b0sttl9GYJ2NzUfgN/AD+OaTAax1TRKdZPtTyhyVHUIBPJX2J5dLDt1FD/kWMQubIWtsCpQiNLRhJIMKDW4CqVDK7O9ad5NAhYZ2zV5DMxWlTKTQtpvNvd0qKrSravodeFasFe27Zp1w6rqGXntfHfvY0kYJPPPBDvZHnL+g98ZBI86aWAAAAABJRU5ErkJggg==) requires 2*r* points, a multiple of four.

The quadruplets of points include 0, ∞, +1, −1 ±2<sup>−</sup>_<sup>i</sup>_. Each of them giving shortcuts for the evaluation phase and for some steps in the interpolation phase. Further tricks are used to reduce the memory footprint of the whole multiplication algorithm to a memory buffer equal in size to the result of the product.

Current GMP uses both Toom-6'n'half and Toom-8'n'half.

### 15.1.6 FFT Multiplication

At large to very large sizes a Fermat style FFT multiplication is used, following Sch¨onhage and Strassen (see Appendix B \[References\], page 130). Descriptions of FFTs in various forms can be found in many textbooks, for instance Knuth section 4.3.3 part C or Lipson chapter IX. A brief description of the form used in GMP is given here.

The multiplication done is _xy_ mod 2*<sup>N</sup>* \+ 1, for a given _N_. A full product _xy_ is obtained by choosing _N_ ≥ bits(_x_)+bits(_y_) and padding _x_ and _y_ with high zero limbs. The modular product is the native form for the algorithm, so padding to get a full product is unavoidable.

The algorithm follows a split, evaluate, pointwise multiply, interpolate and combine similar to that described above for Karatsuba and Toom-3. A _k_ parameter controls the split, with an FFT*k* splitting into 2*<sup>k</sup>* pieces of _M_ \= _N/\_2_<sup>k</sup>_ bits each. \_N_ must be a multiple of 2*<sup>k</sup>*×mp bits per limb so the split falls on limb boundaries, avoiding bit shifts in the split and combine stages.

The evaluations, pointwise multiplications, and interpolation are all done modulo 2*<sup>N</sup>*<sup>0</sup> +1 where _N_<sup>0</sup> is 2*M* \+ _k_ \+ 3 rounded up to a multiple of 2*<sup>k</sup>\_and of mp_bits_per_limb. The results of interpolation will be the following negacyclic convolution of the input pieces, and the choice of \_N*<sup>0</sup> ensures these sums aren't truncated.

![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAc8AAAB3CAYAAABllsuHAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAABPNSURBVHhe7d3fyzRneQfw7+t5Y5LxsHiwiWBQ2YBpFLseJGATtiAIkWyLlBwIj0opKLqBpmfl8RelPerGgIXggdlAIFKqbHIQD4wiXYUILfbgeV/6B+gmmj9ge9Drilcu77nnnrlnZufH9wPD7DM7z+7s7Mx93b8XICIiIqLJ2QE4T2S59h+OiMbnlt9ANEB7AE/6jSPG+466tgDwMID3y9/vBfBvAO64/YhowhYAToFSnC5r/w8dWpnlCsBWgvsxcFxly5V/UaKWbQAcANyY667wOxHR9K0DQUiXkwTYIVhJQI0F0xv/T0Qd2fKaI6LrQCDS5eh3HoBFpL22z9Iyzdderredf4KI5qOoKNFt/T8MRBEIoge/E1EHtLlj458gonlZVrR/rvw/DMjKHfvS7zBzBRN5rFtsgliaa62t1ySiEdsEgqYup4F3jLClZw5b+YOlnJe5n5ONXMNtZAKv5DpjeycRvUPbckLL3u88MDaADjnQ90VrE9gu9/80c5jbLu7bOwvTU5yIZqpw3fD9MvThIBowhn6cXdPvkW3A77aV6yOnal+bCK4kgB7ldXUIS25wJqKRsm06oSUn4enDllVqOI6gqr2JpQSpnLbGQ8a5sfdGKFBqBzaWQolmSsexhZaT33lgCkkg55qA6XfnE/axuzKlvpzvVicHaVIq1/bOskzkSp4b4hAvIurJIRA4dWE72jBpyahJYBiipQQs35SQEzxhMhh1q/d9e6enwfPsnyCi+Sgqhq/MffjDEGmGJze4XJJWq+p1dgpM5JH7+fTarlt9q8dVVqq3wTNUMiWimbCJQWjJaXuidul3NfZS51aWjQtAbQZPmICcOglIyvhO29xRJygT0QT5XL9d5t4xZ0h0mM5UawTaDp4Lea3U0mfK+E6t1o3tQ0QzEpu+b+4D8IdAS51D78yVo+3gCVPNndL2qaXKsvbOgvdEvvf4DUQj9ySAN/1G8feRNiDqx1/LeugTWQzNy7L+mtse879+g/iUrN8E8M/uOSKasTFP3zd12pFlqlW26KjkqVW354QOPnr9l7WRao/gKX8HRNSQ/xUTu4y9o8pY2U5dZR1ZpqCL4AkT9MqCotIeuqHrXO8LVtd2ZCVf0E7q2Ovk1GP7FvJ61xX7EeUqKto/qxIgap926Jp6J5Wugqd28gkFRU9Ln9pGupD/P2WUOBcm/b6OxAa737aHppKu4lVt13JxaxfssyRCVW+is2HELhg7mJ1tHtS1qun7yq5T6obe/ymJ/5h1dY3Z4SUplhJQDrLUDSyWTgCxk7iwlb9PrhpZfxXmWoKm7pcSQ5poGq9gMnOtzLJ0HXhjveDLem4pW00WytnYHl51LgCiHHaaMr9MucfnEOl5n3qp315jbQZPW+1d1e7ZJp1U3le1a+b0JM9tJJDZ/TSYnjuoKs6JVz4e1XbLPF4B+HcAHwDwW7P9COAhALcB3G+2ezcA7pPH9wG4456HfKAvmr/t+w9NAeABv7FjbwP4ld9I2fbSCzfkxZLMHrVrIWkIAPzVxGuebGL8SQCvm79zrAD8RB7/JYAfuee7sAXwWQCPu7igND68COAvAHzafN4lgDfMvq/I67QhN16tAfxQHmcf1yGQI7TROZZLtz3BYvvBtUMNWez3Irtc+sxRzkVhcr+hJWXsHOWxpaY2S2NDZK+tNj+rTY99Wt2FpSlVlrFNcb463tf6tHmf5cQruCpw/zpJtOSnucL3uSi+AfCCPI7l0FP3g8k9VeUMLm0J4DG/sWO/A/Cc30itsLn2kLLaEmqHTSPaLI0N0dk8bvuz6ms/DeDb7rm2HQC8VvE+WtJDoEahAPCvUiJ9FsAz5rkcufEK8tk0fc/6jrYl1Si2lBjrMWXbO1NyF6FcClHXbG7TL1PvAXpp9txPvXbFXldtljxhXrfr9FNrE2OlTrjPmtJJpw1l8cqWgmOBE+64s2wDwbFOVaz9GZ6UGyNU5Cbqg73B/FLVyYCas8Fz6uw1NdbguUzo4GOr4lvpsSqKijiSG6/scTc5j4uqjIKtr44lKnUOWnVxURGlsEOqQktVjpWaaSN4rgO/l9nVcqxIwGPs67Sdzunnb5Lot83GiKpAmyplyGNIarxCZnunvs9NbG5bO4dirB3uYfP4VfO4jFYDNK5jJspwB8Dn/EbjKb+BaEDK5m2+hEfM45+axzk+COAeefy2ey7m8+ZxLF4BwKPm8c/M4xSfkXVpM48tTZbuJOq2d25K6quJ+qQDpO1yk1HaoLg2Sp5jYa+pOqWnFPq6Qyh52hqcaDVmTVc1z1udeAX3/dS1qJpsok5xvG575z4xyBJ1qXAd4k6ssu0UOwy1Q1/30sFTJ0g4t9ze2USdeJXb3vmOskkKbDfe2GBc7TIMqU641z3vFQB+M5JhARyqMn2xbvbULg5VaYe+dh9DVWKuAHxHHn+9xWEoTaTGK0gm7lvyuJNzmFocX5v9UhKezQByKak4ScK02eaGqtwq5eMkCe3Q163b0aVttte67/nqXSUMecmRGq/gjjvruykreZ5lXVWarBvFDwCejwTaAsBXAHxUSqb/ZEqoBYAnpJH6bgBvAfhB5LVyFZyeb7LsdVs1mJraYWupvjDxGhZNP9FyydNO9FFVwuqa/Yx+sgJLaxsfjKRtBYB/lGvEp/sp9FhSJt6xx10W/6yFxJ1HJeZ8r+q8a2SuqhOu0+VXuyDHcgbaHlqYGfsXUho7uhyMvjdLDVTHxl3fseuR2pWaVoydfs5zbunGsTV9XddQXcn9sQvcI/Y4qjrobCviyELS9o1L9/17lrGdhWLvgwbtnUs5Hs1ca8yJXr9aDK46MbbqK/qCcrCxfTRAKi1e7yO9IPW9u6wSoOmwnRxueN30Tu/plIRrzPQaO7ccPPvqsWyD4znQwdOm+7HvspBYEjsHB1ftq534Yv/jpRwLXFNcLBbBBE4bdzT4Rpse7ckpS2BWcmI00MYGpmpbZyw3sXNfkp7EU0nghDnGOiea5klrPs6Bm4L6ocODqjLlY2YzaOeE9sA6NPGvChK5fH8Pm75qSS8lI7SvqBlcuf+3pcg696fGith1ZWuc/GcKOQSac96ZIMFtfxeb0ISCouYo9MdOz5Egt0pMrI4mUBfmQ5blEOyJLgvwRJDryWbG/E1B/bAlmincs0tJ33RZu+FPZ/l77farSgvL6LBAXxJsmx0DbdN/vY+2LpPgv8tC/i8WWCHvY+9FjSXRkl2Ava5CQdEHzrPfwVmWHLtmKkIx8V202Ho2ReuVfHEn9wXqydbteiHtEgOnZ09GWWlVT0g0F0BkcsnnHhIeitNM+RQyMPa6qrOEEuYqsWDVNm171LbIlaxvXElyI9+ntguu5Hm/XyqNN02uDY0HNgZt5FwfXJV3k/OPJtfuWk6EHsSuJLov5AD3st++zps4GoxjPWmTcwE0axySMiz6fUzhvvUlz1C6iMB+dQsTMFWGdUtlTRWSfmt6Hkv3tXPRQe6xJp8vpcBURWOQjVVabW5L02W1mTF9Zl6yaNVHWSnBVuu22aZA06IJzjkjt0ntWsn3ccpIJOeoKk0cu64LQ1qqbRr8kto7L80GxrIcTKjKVnNKRHDtHAcm1IOigYD3axrt3zHVDIftv2JLt5uKz1skluQ1w6ZpQRNdB/dW2OJ7GW1r8PXvg/5g1Jsle9YOmt7jTROyuUkaXzhioVJdIfdwGdup1QddT+NF1X4xtds7L0HrpmM3lp4ImygeMk4MTYe9qcp6gNPlaYLGezZOg8hUS50w14LNHGwrMgu2L8M5Up1tS51N+zyMrr0zduI0cVRXLHWSJC5jG5Kyn2kA0QQplkmmP5Q6x3AtN6VVotp/ZZkwL4AtTZZlLArT1pnT0SpUMh4kDYyxEoO2Z+lYoqY5CpoWO7i7LCc6JJvIjT8HGhjY6S9M2wKnnsFYmqExO1nH0n+Y/bYlpUGbka4KxFVG0d4JORGhk+GlNhbTPIxtSIrmigd/Q3bsOPMMRMzczo0O5UmhNReh/bXk2lZaMIr2TqImxtizVoN96OafE81ETL10Vdc12+wrrU2JVdtINWi21RwymvZOorps7+zc6pm+aOAcfBtKT7R39NxL4UozgyzppFmZ4LlumAYU8v/+nKdM2EM0OmMbklK4dtlYp7i50aq2NqrZxkzbwdsoNVE62+yjtNR5YqmTpqQwgXMMic3KzXLCKrk/VgRy/nOzZkJ9EZqp1czbSu7RMWTKiZLZnnRDH5Kydt3qdWEbH9FwFKYH70nuzyGnK0SNDL3qcyk5WFvS9AtvTCIi6o1tm7hkBxMdKqWdFfSXh3yQDC1zGn5ANEm3/AaiAdsAeMH8/QsAvzV/d+kxvyHD1wE84zcSERG1zc5ROfZl6J2biIhoAuyQlLEvOXNsEtFAsNqWxmAD4Cm/caReBvCc30hERERERERERERERERERERERERERERERERERERERERERERERERERDQf126eW04QT0RElMD+Ogx/05NopN7jNxBRp+6SdZ+/RUpELWPwJOrXn8v6VbediIiIShylynbtnyAiIqI/VpS0d64A7AAcpFMREREN2ArAVcOOK+uWe4uu5Vj6sgBwY4LZye9QYQVgK8sVgKXfIWAt73U0264laC7ldc7y499NFHI8RETUEVsKahIEDwD2fmNDS3MsKUGoTTt539TPspZAuzfBU4PwseL4dajKtQTvo8sw5HwfMD15Y8dARESZdhkllYMsbSjkWPoseaq9BJyU915J4AwFJw3CZc/DtHfuJeD6ILmM/G8KDZ7+dYmIaCDaDJ6XdKpRWtNAW5bh0BLozj/hSvo3Ekj3iUE7FYMnUU84VIXmbAngHgBvAviVfzLgblk/6rarG1kv3HYA+JisXwFwP4AnJXB/pyTYEtGAMXjOz0pKPIdICaoPC9NZ5nChoRsfl/Wr0klHz8uuJAB+CcDTstSl4ztfk/UdAN+Xx1+UNeQ7adphKId+FztTCvffUdl5ISKatI2UjhaSSKe29YXkVNsu5Tg0SBwi1Y0L8145SyggaTXsWYKE9jreSakwdDxlFua1Qu+l7Z32NbWa9SB/FxVtplWaVttey7nQquWTfIajydQsZHvdXslERKOmCbMmrNrzs2npU4NSXf44YDrblAXyVQtLqMSk7Z0+2GkgtENKqmhwDFXB2vZOv/0kGQntNBX6/1SrBsFTj03Pjx6nHpN1aPD6RJN0y2+gydJxhF+Sv0/S3nefVCF6SwB/4jca/yLrL7vt1tuBtsQ1gA8D+LbZdiPH8WBg/64sAbwh7Z33uucKAL+Rxyn3yE6qXp92n8vaA/gxgOfc9gWAr8r6tcj/Q47rAb/R+JC0oX4BwH/7J41fm3l17XWh5wQAPgngdfM/MNdMn98T0SClJAw0PRsAL0jnlcf9k2JvOsiEPCzr/3TbrV8CeMZvdBYAbpcEsS5dSaB51mQo1ArAT+Rx7B4ppDR2D4CnAsGmbWsAf+c3GgWAhxImnX+6JPjFzokG1tvS4YmIaHbamF+1abWtt5FjSZ2koC2xqmKt0o5V2y7NcBNbvbkIVAP3pUm1raVtwKHjtxM8EBHNztK0aal9g04qbQXPWBBDhx2G9H1DgUbHa4aeg2y3HZ6s7QUyAio3eGobcKh9WM+JXidXJZ+fiGiStJetliA0ENSlQSmXT5RDfOefJosPCGXzyOr5Keu4Y0vKOj2fXU4ZnbByrTKCZyhTpfR1tSQe6vRFRDRpGjS2kvg1TQTbCJ7aq/VSwx+OsiwkIPiMhafPVy051eE5coKnXhehTIMG1qNp5y07R0SzEOsMQdN1BeAzAN4C8I2SziNVNHCWdThKoR2XXgyUAPtQAHhCzgWkt+tLJb2PIcf4fr8xIPYaXVpJR6dQT9kqKwD/EOlMtALwt9KJ7PkLVk0TEY1aGyXPqvZOqien5ElENXB6PuqL9ta0M9ZsZIjKS25fIqJBY/Ckpt6ScZyp7PytS6mqBYBHKsYkUrq3Zf1rt52IWsY2T+rLGsDfmIkXXpYSJwMnERERERERERERERERERERUY/YYYiGxv4UWugnzYiIiMhYm198KZsqrk+FTOCwlwkh9vK3/5HoXPpD2JeYZYmIiCbiIMHzksFkKXPu7s2k8gv5+1QxkX0KnUheX+98wQnliYhoArTk6X8JpS/6qyGhXxiBbD9llkA1eK7N7EsMnkRE1IjOz1oWuPpgf3kmRH9dpa05efX1yt6PiAaG0/PR0HxC1q+67X3SX1n5L7dd/UzWn3fbiWgmGDxpaB41j7WjzlHWue2MqR6T9e/ddu8hv4GI5oHBk4ZGA9efyW+NPi6P3wLwRiCA3pg20qZL7k+rEdHMMHjSkOjvUN6WoGnHeH5P1r6d8X4Zr5yz5PygNxHNEIMnDYlt7/S/tnKXrC/VA5eI6B0MnjQk2t75H247AHzEbyAiuhQGTxqSh2X9P247ADwp65fd9i68Ius/dduVloJ/4bYT0UwweNKQ3Jb1Hbd9BeA+ef4591wXHYY0QJeVdj8s6++67aqQY86ZRIGIiCiJzrRje9QWZkYf39O2K3aGoVAArJphSAO6D8pldJKEa/8EERFRlULGdB5l2rqNBKI+x3gqndv2aN57KcdSFcjt5PZlruW19PVsKVgXIhqoW34D0QCspWr0dwB+fsGfJSsAPAHgEQB3y1jTHwN4KdAb2CoAPADgeQAfK9nX/vRamdf9BiIioinTql8imiB2GCLqxlcAfNNvJCIiorCNtHuWdSgiIiIiZ8nASTRt/wdG9Bi557WmBgAAAABJRU5ErkJggg==)

The points used for the evaluation are _g<sup>i</sup>_ for _i_ \= 0 to 2*<sup>k</sup>* − 1 where _g_ \= 2<sup>2</sup>_<sup>N</sup>_<sup>0</sup>_<sup>/</sup>_<sup>2</sup>_<sup>k</sup>_. _g_ is a 2*<sup>k</sup>\_th root of unity mod 2*<sup>N</sup>\_<sup>0</sup> \+ 1, which produces necessary cancellations at the interpolation stage, and it's also a power of 2 so the fast Fourier transforms used for the evaluation and interpolation do only shifts, adds and negations.

The pointwise multiplications are done modulo 2*<sup>N</sup>*<sup>0</sup> \+ 1 and either recurse into a further FFT or use a plain multiplication (Toom-3, Karatsuba or basecase), whichever is optimal at the size _N_<sup>0</sup>. The interpolation is an inverse fast Fourier transform. The resulting set of sums of _x<sub>i</sub>y<sub>j</sub>_ are added at appropriate offsets to give the final result.

Squaring is the same, but _x_ is the only input so it's one transform at the evaluate stage and the pointwise multiplies are squares. The interpolation is the same.

For a mod 2*<sup>N</sup>* \+ 1 product, an FFT-_k_ is an _O_(_N<sup>k/</sup>_<sup>(</sup>_<sup>k</sup>_<sup>−1)</sup>) algorithm, the exponent representing 2*<sup>k</sup>* recursed modular multiplies each 1*/\_2*<sup>k</sup>_<sup>−1</sup> the size of the original. Each successive \_k_ is an asymptotic improvement, but overheads mean each is only faster at bigger and bigger sizes. In the code, MUL*FFT_TABLE and SQR_FFT_TABLE are the thresholds where each \_k* is used. Each new _k_ effectively swaps some multiplying for some shifts, adds and overheads.

A mod 2*<sup>N</sup>* +1 product can be formed with a normal *N*×*N* → 2*N* bit multiply plus a subtraction, so an FFT and Toom-3 etc can be compared directly. A _k_ \= 4 FFT at _O_(_N_<sup>1</sup>_<sup>.</sup>_<sup>333</sup>) can be expected to be the first faster than Toom-3 at _O_(_N_<sup>1</sup>_<sup>.</sup>_<sup>465</sup>). In practice this is what's found, with MUL*FFT* MODF_THRESHOLD and SQR_FFT_MODF_THRESHOLD being between 300 and 1000 limbs, depending on the CPU. So far it's been found that only very large FFTs recurse into pointwise multiplies above these sizes.

When an FFT is to give a full product, the change of _N_ to 2*N* doesn't alter the theoretical complexity for a given _k_, but for the purposes of considering where an FFT might be first used it can be assumed that the FFT is recursing into a normal multiply and that on that basis it's doing 2*<sup>k</sup>* recursed multiplies each 1*/\_2*<sup>k</sup>_<sup>−2</sup> the size of the inputs, making it \_O_(_N<sup>k/</sup>_<sup>(</sup>_<sup>k</sup>_<sup>−2)</sup>). This would mean _k_ \= 7 at _O_(_N_<sup>1</sup>_<sup>.</sup>_<sup>4</sup>) would be the first FFT faster than Toom-3. In practice MUL* FFT_THRESHOLD and SQR_FFT_THRESHOLD have been found to be in the \_k* \= 8 range, somewhere between 3000 and 10000 limbs.

The way _N_ is split into 2*<sup>k</sup>* pieces and then 2*M* \+ _k_ \+ 3 is rounded up to a multiple of 2*<sup>k</sup>* and mp*bits_per_limb means that when 2*<sup>k</sup>_ ≥ mp bits per limb the effective \_N_ is a multiple of 2<sup>2</sup>_<sup>k</sup>_<sup>−1</sup> bits. The +_k_ \+ 3 means some values of _N_ just under such a multiple will be rounded to the next. The complexity calculations above assume that a favourable size is used, meaning one which isn't padded through rounding, and it's also assumed that the extra +_k_ \+ 3 bits are negligible at typical FFT sizes.

The practical effect of the 2<sup>2</sup>_<sup>k</sup>_<sup>−1</sup> constraint is to introduce a step-effect into measured speeds. For example _k_ \= 8 will round _N_ up to a multiple of 32768 bits, so for a 32-bit limb there'll be 512 limb groups of sizes for which mpn*mul_n runs at the same speed. Or for \_k* \= 9 groups of 2048 limbs, _k_ \= 10 groups of 8192 limbs, etc. In practice it's been found each _k_ is used at quite small multiples of its size constraint and so the step effect is quite noticeable in a time versus size graph.

The threshold determinations currently measure at the mid-points of size steps, but this is suboptimal since at the start of a new step it can happen that it's better to go back to the previous _k_ for a while. Something more sophisticated for MUL_FFT_TABLE and SQR_FFT_TABLE will be needed.

### 15.1.7 Other Multiplication

The Toom algorithms described above (see Section 15.1.3 \[Toom 3-Way Multiplication\], page 98, see Section 15.1.4 \[Toom 4-Way Multiplication\], page 100) generalizes to split into an arbitrary number of pieces, as per Knuth section 4.3.3 algorithm C. This is not currently used. The notes here are merely for interest.

In general a split into _r_ \+ 1 pieces is made, and evaluations and pointwise multiplications done at 2*r*+1 points. A 4-way split does 7 pointwise multiplies, 5-way does 9, etc. Asymptotically an (_r_+1)-way algorithm is _O_(_N_<sup>log(2</sup>_<sup>r</sup>_<sup>+1)</sup>_<sup>/</sup>_<sup>log(</sup>_<sup>r</sup>_<sup>+1)</sup>). Only the pointwise multiplications count towards big-_O_ complexity, but the time spent in the evaluate and interpolate stages grows with _r_ and has a significant practical impact, with the asymptotic advantage of each _r_ realized only at bigger and bigger sizes. The overheads grow as _O_(_Nr_), whereas in an _r_ \= 2*<sup>k</sup>* FFT they grow only as _O_(_N_ log*r*).

Knuth algorithm C evaluates at points 0,1,2,. . .,2*r*, but exercise 4 uses −*r*,. . .,0,. . .,_r_ and the latter saves some small multiplies in the evaluate stage (or rather trades them for additions), and has a further saving of nearly half the interpolate steps. The idea is to separate odd and even final coefficients and then perform algorithm C steps C7 and C8 on them separately. The divisors at step C7 become _j_<sup>2</sup> and the multipliers at C8 become 2*tj* − _j_<sup>2</sup>.

Splitting odd and even parts through positive and negative points can be thought of as using −1 as a square root of unity. If a 4th root of unity was available then a further split and speedup would be possible, but no such root exists for plain integers. Going to complex integers with√

_i_ \= −1 doesn't help, essentially because in Cartesian form it takes three real multiplies to do a complex multiply. The existence of 2*<sup>k</sup>\_th roots of unity in a suitable ring or field lets the fast Fourier transform keep splitting and get to \_O*(_N_ log*r*).

Floating point FFTs use complex numbers approximating Nth roots of unity. Some processors have special support for such FFTs. But these are not used in GMP since it's very difficult to guarantee an exact result (to some number of bits). An occasional difference of 1 in the last bit might not matter to a typical signal processing algorithm, but is of course of vital importance to GMP.

### 15.1.8 Unbalanced Multiplication

Multiplication of operands with different sizes, both below MUL_TOOM22_THRESHOLD are done with plain schoolbook multiplication (see Section 15.1.1 \[Basecase Multiplication\], page 96).

For really large operands, we invoke FFT directly.

For operands between these sizes, we use Toom inspired algorithms suggested by Alberto Zanoni and Marco Bodrato. The idea is to split the operands into polynomials of different degree. GMP currently splits the smaller operand into 2 coefficients, i.e., a polynomial of degree 1, but the larger operand can be split into 2, 3, or 4 coefficients, i.e., a polynomial of degree 1 to 3.

## 15.2 Division Algorithms

### 15.2.1 Single Limb Division

N×1 division is implemented using repeated 2×1 divisions from high to low, either with a hardware divide instruction or a multiplication by inverse, whichever is best on a given CPU.

The multiply by inverse follows "Improved division by invariant integers" by M¨oller and Granlund (see Appendix B \[References\], page 130) and is implemented as udiv*qrnnd_preinv in gmp-impl.h. The idea is to have a fixed-point approximation to 1*/d* (see invert_limb) and then multiply by the high limb (plus one bit) of the dividend to get a quotient \_q*. With _d_ normalized (high bit set), _q_ is no more than 1 too small. Subtracting _qd_ from the dividend gives a remainder, and reveals whether _q_ or _q_ − 1 is correct.

The result is a division done with two multiplications and four or five arithmetic operations. On CPUs with low latency multipliers this can be much faster than a hardware divide, though the cost of calculating the inverse at the start may mean it's only better on inputs bigger than say 4 or 5 limbs.

When a divisor must be normalized, either for the generic C \__udiv_qrnnd_c or the multiply by inverse, the division performed is actually \_a_2_<sup>k</sup>_ by \_d_2_<sup>k</sup>_where \_a_ is the dividend and _k_ is the power necessary to have the high bit of _d_2_<sup>k</sup>_ set. The bit shifts for the dividend are usually accomplished "on the fly" meaning by extracting the appropriate bits at each step. Done this way the quotient limbs come out aligned ready to store. When only the remainder is wanted, an alternative is to take the dividend limbs unshifted and calculate \_r_ \= _a_ mod _d_2_<sup>k</sup>_followed by an extra final step \_r_2_<sup>k</sup>_ mod \_d_2_<sup>k</sup>\_. This can help on CPUs with poor bit shifts or few registers.

The multiply by inverse can be done two limbs at a time. The calculation is basically the same, but the inverse is two limbs and the divisor treated as if padded with a low zero limb. This means more work, since the inverse will need a 2×2 multiply, but the four 1×1s to do that are independent and can therefore be done partly or wholly in parallel. Likewise for a 2×1 calculating _qd_. The net effect is to process two limbs with roughly the same two multiplies worth of latency that one limb at a time gives. This extends to 3 or 4 limbs at a time, though the extra work to apply the inverse will almost certainly soon reach the limits of multiplier throughput.

A similar approach in reverse can be taken to process just half a limb at a time if the divisor is only a half limb. In this case the 1×1 multiply for the inverse effectively becomes two ![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAD4AAAA3CAYAAABUzvmMAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAAAJBSURBVGhD7Zu9bhNBEIC/hD6NG0RpgkR3EkpB4SJl5II2Luks8QDmCSh4gUSR6HFH6xpRxRISBRJFHoDKlJTQzEij4Xy/yeGdvU9a3XnG3vN3u9717dmQKY98oIIpcAz89onILIEdsPKJaKykXInwHylhxI99QHgh28/AM5fLimxaPDyjeG6M4rkxiufGKJ4bo3huHLr4Sq4Rlj7RgQmwkfpmPrmP/3WRMjPH7iM/AbZSzw4o/BPKmJuDr5u+6B5Z9JT30pWtrQeqK0P1gK7yraQPlbbyIaSVpvKhpBUrX/ZRCymtWPm1iYeWVrx8K+kj2T4GLlyuLRvgpw8+MAvgo4v9Al4BX1y8lHNz9rqWc1/pQCzd+6hsaUVb/Dnw1uXa8h744YMPjH4NPTOxa+CNeRwO+5neupavmuqSxktPJd50nk+SfdKKH+1DUCethJJvKq2EkG8rrXSWL2SQ0PvlM3kTQ9JVWmklX8j8eCc/DliZZZsd8G6gE9BXWmkkX4jwwickp7+Q2A4gr2tufaQVKz/3SeQgVXNg0eTs3ROFyPeVVub76lOpurW1tZH/p5IU8MvLL2V7WdPqX83+E7OfDF78u9n/ZvarOPGBVJnWdHNkpNeuXvfcUOjIfucTkbGXf40u+iNg5/GyeT4kE+na2Ulv29xwi4BKD/EV9WBQ6SufEOYRe4BKl92mUTbRRnaVrhrEJjLQJYmuq1sK4APwFLj1ScOp2ybN1P0joa5sfAWp4Ft8Abx2sSo+ATc+mAJ/AdZb3xbTRwkqAAAAAElFTkSuQmCC)1 for each limb, which can be a saving on CPUs with a fast half limb multiply, or in fact if the only multiply is a half limb, and especially if it's not pipelined.

### 15.2.2 Basecase Division

Basecase N×M division is like long division done by hand, but in base 2<sup>mp bits per limb</sup>. See Knuth section 4.3.1 algorithm D, and mpn/generic/sb_divrem_mn.c.

Briefly stated, while the dividend remains larger than the divisor, a high quotient limb is formed and the N×1 product _qd_ subtracted at the top end of the dividend. With a normalized divisor (most significant bit set), each quotient limb can be formed with a 2×1 division and a 1×1 multiplication plus some subtractions. The 2×1 division is by the high limb of the divisor and is done either with a hardware divide or a multiply by inverse (the same as in Section 15.2.1 \[Single Limb Division\], page 103) whichever is faster. Such a quotient is sometimes one too big, requiring an addback of the divisor, but that happens rarely.

With Q=N−M being the number of quotient limbs, this is an _O_(_QM_) algorithm and will run at a speed similar to a basecase Q×M multiplication, differing in fact only in the extra multiply and divide for each of the Q quotient limbs.

### 15.2.3 Divide and Conquer Division

For divisors larger than DC_DIV_QR_THRESHOLD, division is done by dividing. Or to be precise by a recursive divide and conquer algorithm based on work by Moenck and Borodin, Jebelean, and Burnikel and Ziegler (see Appendix B \[References\], page 130).

The algorithm consists essentially of recognising that a 2N×N division can be done with the basecase division algorithm (see Section 15.2.2 \[Basecase Division\], page 103), but using N/2 limbs as a base, not just a single limb. This way the multiplications that arise are (N/2)×(N/2) and can take advantage of Karatsuba and higher multiplication algorithms (see Section 15.1 \[Multiplication Algorithms\], page 96). The two "digits" of the quotient are formed by recursive N×(N/2) divisions.

If the (N/2)×(N/2) multiplies are done with a basecase multiplication then the work is about the same as a basecase division, but with more function call overheads and with some subtractions separated from the multiplies. These overheads mean that it's only when N/2 is above MUL_TOOM22_THRESHOLD that divide and conquer is of use.

DC_DIV_QR_THRESHOLD is based on the divisor size N, so it will be somewhere above twice MUL_TOOM22_THRESHOLD, but how much above depends on the CPU. An optimized mpn_mul_basecase can lower DC_DIV_QR_THRESHOLD a little by offering a ready-made advantage over repeated mpn_submul_1 calls.

Divide and conquer is asymptotically _O_(_M_(_N_)log*N*) where _M_(_N_) is the time for an N×N multiplication done with FFTs. The actual time is a sum over multiplications of the recursed sizes, as can be seen near the end of section 2.2 of Burnikel and Ziegler. For example, within the Toom-3 range, divide and conquer is 2*.\_63_M*(_N_). With higher algorithms the _M_(_N_) term improves and the multiplier tends to log*N*. In practice, at moderate to large sizes, a 2N×N division is about 2 to 4 times slower than an N×N multiplication.

### 15.2.4 Block-Wise Barrett Division

For the largest divisions, a block-wise Barrett division algorithm is used. Here, the divisor is inverted to a precision determined by the relative size of the dividend and divisor. Blocks of quotient limbs are then generated by multiplying blocks from the dividend by the inverse.

Our block-wise algorithm computes a smaller inverse than in the plain Barrett algorithm. For a 2*n/n* division, the inverse will be just d_n/\_2e limbs.

### 15.2.5 Exact Division

A so-called exact division is when the dividend is known to be an exact multiple of the divisor. Jebelean's exact division algorithm uses this knowledge to make some significant optimizations (see Appendix B \[References\], page 130).

The idea can be illustrated in decimal for example with 368154 divided by 543. Because the low digit of the dividend is 4, the low digit of the quotient must be 8. This is arrived at from 4×7 mod 10, using the fact 7 is the modular inverse of 3 (the low digit of the divisor), since 3×7≡1 mod 10. So 8×543 = 4344 can be subtracted from the dividend leaving 363810. Notice the low digit has become zero.

The procedure is repeated at the second digit, with the next quotient digit 7 (1×7 mod 10), subtracting 7×543 = 3801, leaving 325800. And finally at the third digit with quotient digit 6 (8×7 mod 10), subtracting 6×543 = 3258 leaving 0. So the quotient is 678.

Notice however that the multiplies and subtractions don't need to extend past the low three digits of the dividend, since that's enough to determine the three quotient digits. For the last quotient digit no subtraction is needed at all. On a 2N×N division like this one, only about half the work of a normal basecase division is necessary.

For an N×M exact division producing Q=N−M quotient limbs, the saving over a normal basecase division is in two parts. Firstly, each of the Q quotient limbs needs only one multiply, not a 2×1 divide and multiply. Secondly, the crossproducts are reduced when _Q > M_ to *QM*−*M*(_M_+1)_/\_2, or when \_Q_ ≤ _M_ to _Q_(_Q_ − 1)\_/\_2\. Notice the savings are complementary. If Q is big then many divisions are saved, or if Q is small then the crossproducts reduce to a small number.

The modular inverse used is calculated efficiently by binvert_limb in gmp-impl.h. This does four multiplies for a 32-bit limb, or six for a 64-bit limb. tune/modlinv.c has some alternate implementations that might suit processors better at bit twiddling than multiplying.

The sub-quadratic exact division described by Jebelean in "Exact Division with Karatsuba Complexity" is not currently implemented. It uses a rearrangement similar to the divide and conquer for normal division (see Section 15.2.3 \[Divide and Conquer Division\], page 104), but operating from low to high. A further possibility not currently implemented is "Bidirectional Exact Integer Division" by Krandick and Jebelean which forms quotient limbs from both the high and low ends of the dividend, and can halve once more the number of crossproducts needed in a 2N×N division.

A special case exact division by 3 exists in mpn_divexact_by3, supporting Toom-3 multiplication and mpq canonicalizations. It forms quotient digits with a multiply by the modular inverse of 3 (which is 0xAA..AAB) and uses two comparisons to determine a borrow for the next limb. The multiplications don't need to be on the dependent chain, as long as the effect of the borrows is applied, which can help chips with pipelined multipliers.

### 15.2.6 Exact Remainder

If the exact division algorithm is done with a full subtraction at each stage and the dividend isn't a multiple of the divisor, then low zero limbs are produced but with a remainder in the high limbs. For dividend _a_, divisor _d_, quotient _q_, and _b_ \= 2<sup>mp bits per limb</sup>, this remainder _r_ is of the form

_a_ \= _qd_ \+ _rb<sup>n</sup>_

_n_ represents the number of zero limbs produced by the subtractions, that being the number of limbs produced for _q_. _r_ will be in the range 0 ≤ _r < d_ and can be viewed as a remainder, but one shifted up by a factor of _b<sup>n</sup>_.

Carrying out full subtractions at each stage means the same number of cross products must be done as a normal division, but there's still some single limb divisions saved. When _d_ is a single limb some simplifications arise, providing good speedups on a number of processors.

The functions mpn*divexact_by3, mpn_modexact_1_odd and the internal mpn_redc_X functions differ subtly in how they return \_r*, leading to some negations in the above formula, but all are essentially the same.

Clearly _r_ is zero when _a_ is a multiple of _d_, and this leads to divisibility or congruence tests which are potentially more efficient than a normal division.

The factor of _b<sup>n</sup>_ on _r_ can be ignored in a GCD when _d_ is odd, hence the use of mpn*modexact* 1_odd by mpn_gcd_1 and mpz_kronecker_ui etc (see Section 15.3 \[Greatest Common Divisor Algorithms\], page 106).

Montgomery's REDC method for modular multiplications uses operands of the form of _xb_<sup>−</sup>_<sup>n</sup>_ and _yb_<sup>−</sup>_<sup>n</sup>_ and on calculating (_xb_<sup>−</sup>_<sup>n</sup>_)(_yb_<sup>−</sup>_<sup>n</sup>_) uses the factor of _b<sup>n</sup>_ in the exact remainder to reach a product in the same form (_xy_)_b_<sup>−</sup>_<sup>n</sup>_ (see Section 15.4.2 \[Modular Powering Algorithm\], page 109).

Notice that _r_ generally gives no useful information about the ordinary remainder _a_ mod _d_ since _b<sup>n</sup>_ mod _d_ could be anything. If however _b<sup>n</sup>_ ≡ 1 mod _d_, then _r_ is the negative of the ordinary remainder. This occurs whenever _d_ is a factor of _b<sup>n</sup>_ −1, as for example with 3 in mpn*divexact* by3. For a 32 or 64 bit limb other such factors include 5, 17 and 257, but no particular use has been found for this.

### 15.2.7 Small Quotient Division

An N×M division where the number of quotient limbs Q=N−M is small can be optimized somewhat.

An ordinary basecase division normalizes the divisor by shifting it to make the high bit set, shifting the dividend accordingly, and shifting the remainder back down at the end of the calculation. This is wasteful if only a few quotient limbs are to be formed. Instead a division of just the top 2Q limbs of the dividend by the top Q limbs of the divisor can be used to form a trial quotient. This requires only those limbs normalized, not the whole of the divisor and dividend.

A multiply and subtract then applies the trial quotient to the M−Q unused limbs of the divisor and N−Q dividend limbs (which includes Q limbs remaining from the trial quotient division). The starting trial quotient can be 1 or 2 too big, but all cases of 2 too big and most cases of 1 too big are detected by first comparing the most significant limbs that will arise from the subtraction. An addback is done if the quotient still turns out to be 1 too big.

This whole procedure is essentially the same as one step of the basecase algorithm done in a Q limb base, though with the trial quotient test done only with the high limbs, not an entire Q limb "digit" product. The correctness of this weaker test can be established by following the argument of Knuth section 4.3.1 exercise 20 but with the _v_<sub>2</sub>^_q > b_^_r_ \+ _u_<sub>2</sub> condition appropriately relaxed.

## 15.3 Greatest Common Divisor

### 15.3.1 Binary GCD

At small sizes GMP uses an _O_(_N_<sup>2</sup>) binary style GCD. This is described in many textbooks, for example Knuth section 4.5.2 algorithm B. It simply consists of successively reducing odd operands _a_ and _b_ using

_a,b_ \= abs(_a_ − _b_)_,\_min(\_a,b_) strip factors of 2 from _a_

The Euclidean GCD algorithm, as per Knuth algorithms E and A, repeatedly computes the quotient _q_ \= b*a/b_c and replaces \_a,b* by _v,u_ − _qv_. The binary algorithm has so far been found to be faster than the Euclidean algorithm everywhere. One reason the binary method does well is that the implied quotient at each step is usually small, so often only one or two subtractions are needed to get the same effect as a division. Quotients 1, 2 and 3 for example occur 67.7% of the time, see Knuth section 4.5.3 Theorem E.

When the implied quotient is large, meaning _b_ is much smaller than _a_, then a division is worthwhile. This is the basis for the initial _a_ mod _b_ reductions in mpn_gcd and mpn_gcd_1 (the latter for both N×1 and 1×1 cases). But after that initial reduction, big quotients occur too rarely to make it worth checking for them.

The final 1 × 1 GCD in mpn*gcd_1 is done in the generic C code as described above. For two N-bit operands, the algorithm takes about 0.68 iterations per bit. For optimum performance some attention needs to be paid to the way the factors of 2 are stripped from \_a*.

Firstly it may be noted that in two's complement the number of low zero bits on _a_ − _b_ is the same as _b_ − _a_, so counting or testing can begin on _a_ − _b_ without waiting for abs(_a_ − _b_) to be determined.

A loop stripping low zero bits tends not to branch predict well, since the condition is data dependent. But on average there's only a few low zeros, so an option is to strip one or two bits arithmetically then loop for more (as done for AMD K6). Or use a lookup table to get a count for several bits then loop for more (as done for AMD K7). An alternative approach is to keep just one of _a_ and _b_ odd and iterate

_a,b_ \= abs(_a_ − _b_)_,\_min(\_a,b_) _a_ \= _a/\_2 if even \_b_ \= \_b/\_2 if even

This requires about 1.25 iterations per bit, but stripping of a single bit at each step avoids any branching. Repeating the bit strip reduces to about 0.9 iterations per bit, which may be a worthwhile tradeoff.

Generally with the above approaches a speed of perhaps 6 cycles per bit can be achieved, which is still not terribly fast with for instance a 64-bit GCD taking nearly 400 cycles. It's this sort of time which means it's not usually advantageous to combine a set of divisibility tests into a GCD.

Currently, the binary algorithm is used for GCD only when _N <_ 3.

### 15.3.2 Lehmer's algorithm

Lehmer's improvement of the Euclidean algorithms is based on the observation that the initial part of the quotient sequence depends only on the most significant parts of the inputs. The variant of Lehmer's algorithm used in GMP splits off the most significant two limbs, as suggested, e.g., in "A Double-Digit Lehmer-Euclid Algorithm" by Jebelean (see Appendix B \[References\], page 130). The quotients of two double-limb inputs are collected as a 2 by 2 matrix with singlelimb elements. This is done by the function mpn_hgcd2. The resulting matrix is applied to the inputs using mpn_mul_1 and mpn_submul_1. Each iteration usually reduces the inputs by almost one limb. In the rare case of a large quotient, no progress can be made by examining just the most significant two limbs, and the quotient is computed using plain division.

The resulting algorithm is asymptotically _O_(_N_<sup>2</sup>), just as the Euclidean algorithm and the binary algorithm. The quadratic part of the work are the calls to mpn*mul_1 and mpn_submul_1. For small sizes, the linear work is also significant. There are roughly \_N* calls to the mpn_hgcd2 function. This function uses a couple of important optimizations:

- It uses the same relaxed notion of correctness as mpn_hgcd (see next section). This means that when called with the most significant two limbs of two large numbers, the returned matrix does not always correspond exactly to the initial quotient sequence for the two large numbers; the final quotient may sometimes be one off.
- It takes advantage of the fact that the quotients are usually small. The division operator is not used, since the corresponding assembler instruction is very slow on most architectures. (This code could probably be improved further, it uses many branches that are unfriendly to prediction.)
- It switches from double-limb calculations to single-limb calculations half-way through, when the input numbers have been reduced in size from two limbs to one and a half.

### 15.3.3 Subquadratic GCD

For inputs larger than GCD_DC_THRESHOLD, GCD is computed via the HGCD (Half GCD) function, as a generalization to Lehmer's algorithm.

Let the inputs _a,b_ be of size _N_ limbs each. Put _S_ \= b*N/\_2c + 1. Then HGCD(a,b) returns a transformation matrix \_T* with non-negative elements, and reduced numbers (_c_;_d_) = _T_<sup>−1</sup>(_a_;_b_). The reduced numbers _c,d_ must be larger than _S_ limbs, while their difference _abs_(*c*−*d*) must fit in _S_ limbs. The matrix elements will also be of size roughly \_N/\_2.

The HGCD base case uses Lehmer's algorithm, but with the above stop condition that returns reduced numbers and the corresponding transformation matrix half-way through. For inputs larger than HGCD_THRESHOLD, HGCD is computed recursively, using the divide and conquer algorithm in "On Sch¨onhage's algorithm and subquadratic integer GCD computation" by M¨oller (see Appendix B \[References\], page 130). The recursive algorithm consists of these main steps.

- Call HGCD recursively, on the most significant _N/\_2 limbs. Apply the resulting matrix \_T_<sub>1</sub> to the full numbers, reducing them to a size just above 3_N/\_2.
- Perform a small number of division or subtraction steps to reduce the numbers to size below 3_N/\_2\. This is essential mainly for the unlikely case of large quotients.
- Call HGCD recursively, on the most significant _N/\_2 limbs of the reduced numbers. Apply the resulting matrix \_T_<sub>2</sub> to the full numbers, reducing them to a size just above \_N/\_2.
- Compute _T_ \= _T_<sub>1</sub>_T_<sub>2</sub>.
- Perform a small number of division and subtraction steps to satisfy the requirements, and return.

GCD is then implemented as a loop around HGCD, similarly to Lehmer's algorithm. Where Lehmer repeatedly chops off the top two limbs, calls mpn*hgcd2, and applies the resulting matrix to the full numbers, the sub-quadratic GCD chops off the most significant third of the limbs (the proportion is a tuning parameter, and 1*/_3 seems to be more efficient than, e.g., 1_/\_2), calls mpn_hgcd, and applies the resulting matrix. Once the input numbers are reduced to size below GCD_DC_THRESHOLD, Lehmer's algorithm is used for the rest of the work.

The asymptotic running time of both HGCD and GCD is _O_(_M_(_N_)log*N*), where _M_(_N_) is the time for multiplying two _N_\-limb numbers.

### 15.3.4 Extended GCD

The extended GCD function, or GCDEXT, calculates gcd(_a,b_) and also cofactors _x_ and _y_ satisfying _ax_ \+ _by_ \= gcd(_a,b_). All the algorithms used for plain GCD are extended to handle this case. The binary algorithm is used only for single-limb GCDEXT. Lehmer's algorithm is used for sizes up to GCDEXT*DC_THRESHOLD. Above this threshold, GCDEXT is implemented as a loop around HGCD, but with more book-keeping to keep track of the cofactors. This gives the same asymptotic running time as for GCD and HGCD, \_O*(_M_(_N_)log*N*).

One difference to plain GCD is that while the inputs _a_ and _b_ are reduced as the algorithm proceeds, the cofactors _x_ and _y_ grow in size. This makes the tuning of the chopping-point more difficult. The current code chops off the most significant half of the inputs for the call to HGCD in the first iteration, and the most significant two thirds for the remaining calls. This strategy could surely be improved. Also the stop condition for the loop, where Lehmer's algorithm is invoked once the inputs are reduced below GCDEXT_DC_THRESHOLD, could maybe be improved by taking into account the current size of the cofactors.

### 15.3.5 Jacobi Symbol

Jacobi symbol ![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADcAAAA2CAYAAABjhwHjAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAAAP8SURBVGhD3ZoxixQxFMf/ai2nTmu1VqIyoHKKXGN7CGIhWCoWZ2FlsX6CE/wCCwqi5X0CWf0ANntaHVh4WohgoyNqYbk277/+fSazk0nOu70fLMm+zEzyXl5eJskA+5hDXjCHIYAlAO98wX+iAnAVwGcAv3xhDhsAtgEMfMF/ZgJgbIoWYQSgAVD7gl2gMiMXUXAEYArghi/YRWozdpaCN0yxDV+wB1izto18QRcGZp29MM5ijPt6FW9c8wU9WJWANLZfbS41zHCtFWtjUgfQHbczKobduxEwUm3PnljZUMpSYUxY9wUxtgtUWknjQ25DA06tZ/vC3mss3worbVK6OgAtGgtGbNQ00zsgRozVNYMXjn1BAtrw2NzIaDfxBT3gs1o7pJZGhVypKxxn275A4DWdx0oLlbQ7OpTWxQIxi3eBFbU1vLFrcsabwugeNSgDSY6rqEvGel89JHe8kaE8cwUADkphDeCE5V+KPIdPXmBctHQTwFfLr7YYowuvJH8JTjlWCAAfJZ/KW8n/lLxyzVI14hXJ90HrvS55QAb4NHO8Qfw/NO9wipjK4Oebfq6LMtI3ACrtufOWfmtxp67ct+fcFdlA5qEHli5ZehvAY3HRvvD+owCOU6ihtPlzbRa1e5+cuMi4bnVN5kTVFDSozF73NMLNneX3MKrcurrlfkAj5gkqd0mE+4UjoZ574wULynJIue9esKgcsHQI4KHl7wB4JNek8NQLenLLCzpSAfhi+W8UBkNoD/iM3F8OfEZTuuduekFPnnlBAjRO8Z7bbXS10YQCCl+JFpHD+iek3FkvWFBmPbflCvYDm1TuhwiPSH7RmK0EIPMcXJQ5JvIcKgAXAJwW2RaA5/K/JD7qz+D+Se48o9Sy3OGzS20IhdCF8F/1lFyJe3RJFd1XLAB3AKYABhot9YX5pORLcMrS9wA+uLKSLFv6HsAHVe6F5M9IvgSXLS21qxZiYNsLiNVTYt8yBDdgc7bu5jH3YEUHZO5OFNFXop0cb3PbXuqsQOEhhW5zr9gv2Iie0Ota94B4Uc4pj8IoPLJ5iLtd/EIienCRgHZK0CWJ+m4Jy3K8hRRhXV6eCl2yU6wocbIKZ9HYUirXkFVqwNLT1RxC481D5UJb713Qg8fOlPiaocsB47yebYNnDMnGqc0aTYbLzHMXfS1rDQQRuIPQGiFjsMv73NxlfuPz266JwY+AktzR0/fbL/0AJgZXC52inIPDJvslnwqmWJfKxebLgfRa0niRs/s+rvwPlTWySVCQjY8pR4OlfpjGSF5EMWWY6J40iA9IbOA4UNYGo2NxxfrAiDuyhlUS4dqmhyLoHspOUQG4B+Cc/X8N4MkOL1oBAL8BMlBenU93J74AAAAASUVORK5CYII=)

Initially if either operand fits in a single limb, a reduction is done with either mpn_mod_1 or mpn_modexact_1_odd, followed by the binary algorithm on a single limb. The binary algorithm is well suited to a single limb, and the whole calculation in this case is quite efficient.

For inputs larger than GCD_DC_THRESHOLD, mpz_jacobi, mpz_legendre and mpz_kronecker are computed via the HGCD (Half GCD) function, as a generalization to Lehmer's algorithm.

Most GCD algorithms reduce _a_ and _b_ by repeatedly computing the quotient _q_ \= b_a/b_c and iteratively replacing

_a,b_ \= _b,a_ − _q_ ∗ _b_

Different algorithms use different methods for calculating q, but the core algorithm is the same if we use Section 15.3.2 \[Lehmer's Algorithm\], page 107 or Section 15.3.3 \[Subquadratic GCD\], page 107.

At each step it is possible to compute if the reduction inverts the Jacobi symbol based on the two least significant bits of _a_ and _b_. For more details see "Efficient computation of the Jacobi symbol" by M¨oller (see Appendix B \[References\], page 130).

A small set of bits is thus used to track state

- current sign of result (1 bit)
- two least significant bits of _a_ and _b_ (4 bits)
- a pointer to which input is currently the denominator (1 bit)

In all the routines sign changes for the result are accumulated using fast bit twiddling which avoids conditional jumps.

The final result is calculated after verifying the inputs are coprime (GCD = 1) by raising (−1)_<sup>e</sup>_.

Much of the HGCD code is shared directly with the HGCD implementations, such as the 2x2 matrix calculation, See Section 15.3.2 \[Lehmer's Algorithm\], page 107 basecase and GCD*DC* THRESHOLD.

The asymptotic running time is _O_(_M_(_N_)log*N*), where _M_(_N_) is the time for multiplying two _N_\-limb numbers.

## 15.4 Powering Algorithms

### 15.4.1 Normal Powering

Normal mpz or mpf powering uses a simple binary algorithm, successively squaring and then multiplying by the base when a 1 bit is seen in the exponent, as per Knuth section 4.6.3. The "left to right" variant described there is used rather than algorithm A, since it's just as easy and can be done with somewhat less temporary memory.

### 15.4.2 Modular Powering

Modular powering is implemented using a 2*<sup>k</sup>*\-ary sliding window algorithm, as per "Handbook of Applied Cryptography" algorithm 14.85 (see Appendix B \[References\], page 130). _k_ is chosen according to the size of the exponent. Larger exponents use larger values of _k_, the choice being made to minimize the average number of multiplications that must supplement the squaring.

The modular multiplies and squarings use either a simple division or the REDC method by Montgomery (see Appendix B \[References\], page 130). REDC is a little faster, essentially saving N single limb divisions in a fashion similar to an exact remainder (see Section 15.2.6 \[Exact Remainder\], page 105).

## 15.5 Root Extraction Algorithms

### 15.5.1 Square Root

Square roots are taken using the "Karatsuba Square Root" algorithm by Paul Zimmermann (see Appendix B \[References\], page 130).

An input _n_ is split into four parts of _k_ bits each, so with _b_ \= 2*<sup>k</sup>* we have _n_ \= _a_<sub>3</sub>_b_<sup>3</sup>+_a_<sub>2</sub>_b_<sup>2</sup>+_a_<sub>1</sub>_b_+_a_<sub>0</sub>. Part _a_<sub>3</sub> must be "normalized" so that either the high or second highest bit is set. In GMP, _k_ is kept on a limb boundary and the input is left shifted (by an even number of bits) to normalize.

The square root of the high two parts is taken, by recursive application of the algorithm (bottoming out in a one-limb Newton's method),

_s_<sup>0</sup>_,r_<sup>0</sup> \= sqrtrem (_a_<sub>3</sub>_b_ \+ _a_<sub>2</sub>)

This is an approximation to the desired root and is extended by a division to give _s_,_r_,

_q,u_ \= divrem (_r_<sup>0</sup>_b_ \+ _a_<sub>1</sub>_,\_2_s_<sup>0</sup>)

_s_ \= _s_<sup>0</sup>_b_ \+ _q r_ \= _ub_ \+ _a_<sub>0</sub> − _q_<sup>2</sup>

The normalization requirement on _a_<sub>3</sub> means at this point _s_ is either correct or 1 too big. _r_ is negative in the latter case, so

if _r <_ 0 then _r_ ← _r_ \+ 2*s* − 1 _s_ ← _s_ − 1

The algorithm is expressed in a divide and conquer form, but as noted in the paper it can also be viewed as a discrete variant of Newton's method, or as a variation on the schoolboy method (no longer taught) for square roots two digits at a time.

If the remainder _r_ is not required then usually only a few high limbs of _r_ and _u_ need to be calculated to determine whether an adjustment to _s_ is required. This optimization is not currently implemented.

In the Karatsuba multiplication range this algorithm is ![](data:image/png;base64,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)2)), where _M_(_n_) is the time to multiply two numbers of _n_ limbs. In the FFT multiplication range this grows to a bound of _O_(6*M*(\_N/\_2)). In practice a factor of about 1.5 to 1.8 is found in the Karatsuba and Toom-3 ranges, growing to 2 or 3 in the FFT range.

The algorithm does all its calculations in integers and the resulting mpn_sqrtrem is used for both mpz_sqrt and mpf_sqrt. The extended precision given by mpf_sqrt_ui is obtained by padding with zero limbs.

### 15.5.2 Nth Root

Integer Nth roots are taken using Newton's method with the following iteration, where _A_ is the input and _n_ is the root to be taken.

![](data:image/png;base64,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)

The initial approximation _a_<sub>1</sub> is generated bitwise by successively powering a trial root with or without new 1 bits, aiming to be just above the true root. The iteration converges quadratically when started from a good approximation. When _n_ is large more initial bits are needed to get good convergence. The current implementation is not particularly well optimized.

### 15.5.3 Perfect Square

A significant fraction of non-squares can be quickly identified by checking whether the input is a quadratic residue modulo small integers.

mpz_perfect_square_p first tests the input mod 256, which means just examining the low byte. Only 44 different values occur for squares mod 256, so 82.8% of inputs can be immediately identified as non-squares.

On a 32-bit system similar tests are done mod 9, 5, 7, 13 and 17, for a total 99.25% of inputs identified as non-squares. On a 64-bit system 97 is tested too, for a total 99.62%.

These moduli are chosen because they're factors of 2<sup>24</sup> − 1 (or 2<sup>48</sup> − 1 for 64-bits), and such a remainder can be quickly taken just using additions (see mpn_mod_34lsub1).

When nails are in use moduli are instead selected by the gen-psqr.c program and applied with an mpn_mod_1. The same 2<sup>24</sup> −1 or 2<sup>48</sup> −1 could be done with nails using some extra bit shifts, but this is not currently implemented.

In any case each modulus is applied to the mpn_mod_34lsub1 or mpn_mod_1 remainder and a table lookup identifies non-squares. By using a "modexact" style calculation, and suitably permuted tables, just one multiply each is required, see the code for details. Moduli are also combined to save operations, so long as the lookup tables don't become too big. gen-psqr.c does all the pre-calculations.

A square root must still be taken for any value that passes these tests, to verify it's really a square and not one of the small fraction of non-squares that get through (i.e. a pseudo-square to all the tested bases).

Clearly more residue tests could be done, mpz_perfect_square_p only uses a compact and efficient set. Big inputs would probably benefit from more residue testing, small inputs might be better off with less. The assumed distribution of squares versus non-squares in the input would affect such considerations.

### 15.5.4 Perfect Power

Detecting perfect powers is required by some factorization algorithms. Currently mpz*perfect* power_p is implemented using repeated Nth root extractions, though naturally only prime roots need to be considered. (See Section 15.5.2 \[Nth Root Algorithm\], page 110.)

If a prime divisor _p_ with multiplicity _e_ can be found, then only roots which are divisors of _e_ need to be considered, much reducing the work necessary. To this end divisibility by a set of small primes is checked.

## 15.6 Radix Conversion

Radix conversions are less important than other algorithms. A program dominated by conversions should probably use a different data representation.

### 15.6.1 Binary to Radix

Conversions from binary to a power-of-2 radix use a simple and fast _O_(_N_) bit extraction algorithm.

Conversions from binary to other radices use one of two algorithms. Sizes below GET*STR* PRECOMPUTE*THRESHOLD use a basic \_O*(_N_<sup>2</sup>) method. Repeated divisions by _b<sup>n</sup>_ are made, where _b_ is the radix and _n_ is the biggest power that fits in a limb. But instead of simply using the remainder _r_ from such divisions, an extra divide step is done to give a fractional limb representing _r/b<sup>n</sup>_. The digits of _r_ can then be extracted using multiplications by _b_ rather than divisions.

Special case code is provided for decimal, allowing multiplications by 10 to optimize to shifts and adds.

Above GET*STR_PRECOMPUTE_THRESHOLD_i* a sub-quadratic algorithm is used.√ For an input _t_,

powers _b<sup>n</sup>_<sup>2</sup> of the radix are calculated, until a power between _t_ and _t_ is reached. _t_ is then divided by that largest power, giving a quotient which is the digits above that power, and a remainder which is those below. These two parts are in turn divided by the second highest power, and so on recursively. When a piece has been divided down to less than GET_STR_DC_THRESHOLD limbs, the basecase algorithm described above is used.

The advantage of this algorithm is that big divisions can make use of the sub-quadratic divide and conquer division (see Section 15.2.3 \[Divide and Conquer Division\], page 104), and big divisions tend to have less overheads than lots of separate single limb divisions anyway. But in any case the cost of calculating the powers _b<sup>n</sup>_<sup>2</sup>_<sup>i</sup>_ must first be overcome.

GET*STR_PRECOMPUTE_THRESHOLD and GET_STR_DC_THRESHOLD represent the same basic thing, the point where it becomes worth doing a big division to cut the input in half. GET_STR* PRECOMPUTE*THRESHOLD includes the cost of calculating the radix power required, whereas GET* STR_DC_THRESHOLD assumes that's already available, which is the case when recursing.

Since the base case produces digits from least to most significant but they want to be stored from most to least, it's necessary to calculate in advance how many digits there will be, or at least be sure not to underestimate that. For GMP the number of input bits is multiplied by chars_per_bit_exactly from mp_bases, rounding up. The result is either correct or one too big.

Examining some of the high bits of the input could increase the chance of getting the exact number of digits, but an exact result every time would not be practical, since in general the difference between numbers 100. . . and 99. . . is only in the last few bits and the work to identify 99. . . might well be almost as much as a full conversion.

The _r/b<sup>n</sup>_ scheme described above for using multiplications to bring out digits might be useful for more than a single limb. Some brief experiments with it on the base case when recursing didn't give a noticeable improvement, but perhaps that was only due to the implementation. Something similar would work for the sub-quadratic divisions too, though there would be the cost of calculating a bigger radix power.

Another possible improvement for the sub-quadratic part would be to arrange for radix powers that balanced the sizes of quotient and remainder produced, i.e. the highest power would be an√

_b<sup>nk</sup>_ approximately equal to _t_, not restricted to a 2*<sup>i</sup>* factor. That ought to smooth out a graph of times against sizes, but may or may not be a net speedup.

### 15.6.2 Radix to Binary

This section needs to be rewritten, it currently describes the algorithms used before GMP 4.3.

Conversions from a power-of-2 radix into binary use a simple and fast _O_(_N_) bitwise concatenation algorithm.

Conversions from other radices use one of two algorithms. Sizes below SET*STR_PRECOMPUTE* THRESHOLD use a basic _O_(_N_<sup>2</sup>) method. Groups of _n_ digits are converted to limbs, where _n_ is the biggest power of the base _b_ which will fit in a limb, then those groups are accumulated into the result by multiplying by _b<sup>n</sup>_ and adding. This saves multi-precision operations, as per Knuth section 4.4 part E (see Appendix B \[References\], page 130). Some special case code is provided for decimal, giving the compiler a chance to optimize multiplications by 10.

Above SET*STR_PRECOMPUTE_THRESHOLD a sub-quadratic algorithm is used. First groups of \_n* digits are converted into limbs. Then adjacent limbs are combined into limb pairs with _xb<sup>n</sup>_ +_y_, where _x_ and _y_ are the limbs. Adjacent limb pairs are combined into quads similarly with _xb_<sup>2</sup>_<sup>n</sup>_+_y_. This continues until a single block remains, that being the result.

The advantage of this method is that the multiplications for each _x_ are big blocks, allowing Karatsuba and higher algorithms to be used. But the cost of calculating the powers _b<sup>n</sup>_<sup>2</sup>_<sup>i</sup>_ must be overcome. SET_STR_PRECOMPUTE_THRESHOLD usually ends up quite big, around 5000 digits, and on some processors much bigger still.

SET_STR_PRECOMPUTE_THRESHOLD is based on the input digits (and tuned for decimal), though it might be better based on a limb count, so as to be independent of the base. But that sort of count isn't used by the base case and so would need some sort of initial calculation or estimate.

The main reason SET_STR_PRECOMPUTE_THRESHOLD is so much bigger than the corresponding GET_STR_PRECOMPUTE_THRESHOLD is that mpn_mul_1 is much faster than mpn_divrem_1 (often by a factor of 5, or more).

## 15.7 Other Algorithms

### 15.7.1 Prime Testing

The primality testing in mpz_probab_prime_p (see Section 5.9 \[Number Theoretic Functions\], page 38) first does some trial division by small factors and then uses the Miller-Rabin probabilistic primality testing algorithm, as described in Knuth section 4.5.4 algorithm P (see Appendix B \[References\], page 130).

For an odd input _n_, and with _n_ \= _q_2_<sup>k</sup>_ \+ 1 where \_q_ is odd, this algorithm selects a random base _x_ and tests whether _x<sup>q</sup>_ mod _n_ is 1 or −1, or an _x<sup>q</sup>_<sup>2</sup>_<sup>j</sup>_ mod _n_ is 1, for 1 ≤ _j_ ≤ _k_. If so then _n_ is probably prime, if not then _n_ is definitely composite.

Any prime _n_ will pass the test, but some composites do too. Such composites are known as strong pseudoprimes to base _x_. No _n_ is a strong pseudoprime to more than 1*/\_4 of all bases (see Knuth exercise 22), hence with \_x* chosen at random there's no more than a 1\_/_4 chance a "probable prime" will in fact be composite.

In fact strong pseudoprimes are quite rare, making the test much more powerful than this analysis would suggest, but 1*/\_4 is all that's proven for an arbitrary \_n*.

### 15.7.2 Factorial

Factorials are calculated by a combination of two algorithms. An idea is shared among them: to compute the odd part of the factorial; a final step takes account of the power of 2 term, by shifting.

For small _n_, the odd factor of _n_! is computed with the simple observation that it is equal to the product of all positive odd numbers smaller than _n_ times the odd factor of b*n/\_2c!, where b_x_c is the integer part of \_x*, and so on recursively. The procedure can be best illustrated with an example,

23! = (23*.\_21*._19_._17_._15_._13_._11_._9_._7_._5_._3)(11_._9_._7_._5_._3)(5_.\_3)2<sup>19</sup>

Current code collects all the factors in a single list, with a loop and no recursion, and computes the product, with no special care for repeated chunks.

When _n_ is larger, computations pass through prime sieving. A helper function is used, as suggested by Peter Luschny:

_n_

msf(

![](data:image/png;base64,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)_p_\=3

Where _p_ ranges on odd prime numbers. The exponent _k_ is chosen to obtain an odd integer number: _k_ is the number of 1 bits in the binary representation of b*n/\_2c. The function L(\_p,n*) can be defined as zero when _p_ is composite, and, for any prime _p_, it is computed with:

L![](data:image/png;base64,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)

With this helper function, we are able to compute the odd part of _n_! using the recursion implied by _n_! = b*n/\_2c!<sup>2</sup> · msf(\_n*) · 2*<sup>k</sup>*. The recursion stops using the small-_n_ algorithm on some b*n/\_2*<sup>i</sup>\_c.

Both the above algorithms use binary splitting to compute the product of many small factors. At first as many products as possible are accumulated in a single register, generating a list of factors that fit in a machine word. This list is then split into halves, and the product is computed recursively.

Such splitting is more efficient than repeated N×1 multiplies since it forms big multiplies, allowing Karatsuba and higher algorithms to be used. And even below the Karatsuba threshold a big block of work can be more efficient for the basecase algorithm.

### 15.7.3 Binomial Coefficients

Binomial coefficients ![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADoAAAA2CAYAAACWeYpTAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAAAPQSURBVGhD7Zo/jhMxFMY/cQBWq3QUFKFCQkoBBYJUSLDabaHIDXKDucFegGLPkIIDjKCg2yYIiQLRBAok2ixoDxCa962+vNgz9oyzy474SZE9Y8fj5/fHM7aB/+wwAlADmPmCG6ICsLB+FWMEYGWCFm24ByMAy5J9YoOrUg0WZAxgXUrYJYANgIkvaGFi5jUPdGJsLlDZL7dtZWr9q31BDqfWSOULWpjaAJ1YuhZhKrs3t3qVPePMtZFD134CMlLLgEbaWJnWIIIsTJiQQLSaqS9IZGSDmW15DD4b00oO1CahoE1aq/toxJiLYpJh57L+ZJzaQwmFWMk9DzWq/+sCtZo0BaoZJP3BMXamTm3G2hpJnSyzC0AFJc0QrLxOqdwC/XzT0NZMnteXccLAXkHfjPlTDhy0ptC/KPg8iKs0ut2JjEhuEArRFmTUbDXi9jFhWsimqZ0zMSNOD30ICaGwUxqoGCO6ouZ76gsJg1CTqaWS4p/UuHZoVsCM6X7BSK8di5laDilTFAWlxjl/97Um+v2Gbd2RwmeS/yn5rryw9L27r7y19Ng0WQN4DeCHq5fLR8m/lDwgo7tpcuIMJpEXeg9f/quEuqmode64Af2zTyD4V9CAtOU6WhB04FsI5VlDfPSeVPgk+dvMd0sPAUwo6F2pMBS2LJOCPtKbA+ShTi9EQ/NQOAgJOhR+68WQBf2sF0MWdIshC3qgF0MW9LFehAS9728MgZCgD/yNAfCVgp67gqFxSUEv5eZQNHpk6YWTb/ttvyBjWyqp7cc9mX0T/HqBfLUcFvwAJn/sTeUIwBMAv3yFwuhi3M4KB1cAS60weLiUWtpiQuiybQWn0S+Sfyr5Ujy3dGeE94B+jZ3DCfpB8vvQ6CtLr+PriAtzFwC+uTJAdrVKL6eU3EhKgc9a+AKie5l911aV6/RPXQG82mjyb0bvJP9G8n1p8s+RnGcoMe0cW3rh3HGHpN2oTGIbvTM5z3BiGm/d7muB2xHRfReiqi/hTzH/9OcZOBhRv0pAXSTJ9UKbP13ROY2cBTS341cdYL+TBytlJywVHo2pra1lRJhJTwviIvw6tx2+KfXVKk1yab+sTmRAbfo40Aq38Lxv5aD+Wdtor820QlrtCi2QVpNNn0NViMyf05zImAAVsuqhEEC237t0iv7pg4MGKI2O49RoKdDFSszBV6eychuLzZ+TiKChaNxE1341wtfD2MELT2z+hLiEmvTIrlNdhFZRVEgyzRA05J+EU4F+PFSZ7pHTl71CC/D+Sei/c/t1DXg3Ds8mNHV+anW8DxfnLxlTQKit9p0EAAAAAElFTkSuQmCC) are calculated by first arranging _k_ ≤ _n/\_2 using ![](data:image/png;base64,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) if necessary, and then evaluating the following product simply from \_i_ \= 2 to _i_ \= _k_.

![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAnMAAAB7CAYAAAAffAZKAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAABm0SURBVHhe7d3vqyX1fQfwtz4Xo+OjxIicTaFiy5HEtCG5lSr4g9s8SInUayklYPBGCwUTubaJeVRWojQVitxNgoE8SJtrmmAetObuBhRalepdQwSDgd5dgkgeuWcV/4DbB/v5bN772Zk5M3PmOz/OvF8wnDkzZ889O2fOzGc+38/3O4CIiIiIjNYVcYGIiEhDG+H5y+G5iIiIiAzUUZiOxxeISBpXxgUiIiINXAHgOnr+Cs2LiIiIyAjMKTOXxZUikoYycyIi0pbP2ONpAOfCOhFJRMGciIi05XZ7PBWWi4iIiMgILKyJdTOuEBEREZFhU72cSE/UzCoiIm0oq5fbAnAAYB/AYc54dCKyAgVzIiLShrx6uQzAHoAbANwD4DFb/jS9RkREREQGINbLZZaJ4/q5fXvNIS0TERERkZ5xvdzMnu/bI9ux5WpmnY7Mvu8Na27fUQeZ4csA7NqPdej2bBIRkdVsU8ZtqyCQk2nhAD9OutXbgGVW4DqWL2rLPuuBXUmKiEgze3SiXtg5QNm3acssyN+x/YGDOWXm6vNk2VHKhNnYAjnnV5MLBXQiIo15vdy2XSj7SWdhz0U4mNPQNfX5b8qn1i+WxhrIOT7oKKATEamnaHy5TVquY+u08T5yEFdKJd55yOOV1gNi/wP7Kd68I95EoB5WIiL1eAtH3knaM3Y7tGw+0gt/ac73kTEkfTLbX4cWz2za7+kwRTO1Z7UOB/gfr4Ozi8naokVE1pBfDOedpP0Ezk1Cx+3kLtPBNZWtByIt83r6yZQH7FC6bx16Lc3pKjLvoCQiIpeL48sxP4H7xX6mkpZJ8n2E94Wh8tiGs8lra4O+mHW6wvKIvOjAJCIiv1dUL+e89caPp7tTOUnKRWOrl5tMMOdXVkdrOk6bp4N19SgiUs5P1LtxhfHhFBZ2Il/7E6RcZkz1cphSMLfuwQ4Hq6qfExERaW5M9XKYSjDHXc3bbl7NS9EXSR1EcnNr2/9PEREZriGdi9ZB3Xq5vrfp0IK51rcHZ6zabPf2kaEXNuVtwJm97tBe648HCXuceO/WRcUdUEREximzlhg/xxUN/7BBzcY+HVn2qfVBXNdA1Xq5jTBEWJ/B1FCCuW3bv3x7tDb8G48+nLeTN7FjX7B/QB+zjtvVt+w/sxMi1NS9T7mTxzrWBoqIyAX7VPfHiQs+13lCYSucVNVxrliVejnerrDzfOw406UhBHO74VajfPvRlXB03VZgM7P34wDNN6IvP77k3qm8oxS9ZhU84vI6DL8iIiKX8oQB82O/Lz+wE2xRZkQDz+dbVi+3a6/x7ToLzbJ9BFR9B3ObIcmFkFzKzQBfGRcUeNIezwN4Jqxr6gEAJwCcjSvMEwDuAnBPyWt+TfP30nxbHqb5Z2leRETWw9cAPB4XmmMWbBzY+eBcfIH5pT0eKzrZTtRdNP8bmgdlQrdou94L4Bp6zdRkAH4I4JGwr91M85+l+YuqBHMbAO62+dcBvBzWN3UfgP8My26k+bvsNUU/ni6cBXDS5m8tuLIQEZFxmtmx/Rdh+Sdo/li4sJdq5hSYnQlJGQ/k4nZ9h+bPA/g+PZ+CewvirNtp/i2ar4WbGtsKZryJNaasvdDvqGIvUm5mTZUS5fTmyu3VIiIyGFs5x3U/P/lUpcSGmxOVmbuAz888DuFuybiEsDhjOyc+6EqfzaxcO+gy2o6NO2SmCmSW/YAWYV0R7pQRN0CbvGfrUYsBrYiI9Gs3pzCfOzRUrRHnRESK+u0x4gDXO40sC+SGoK9grijJVRQUX+KKuCDYBfCQzX8FwHfD+qYyAFeHtOsWgB/Z/HMVg7NDS4EDwC0A3gzr29Lks4mIyLDNAHwQynnqnvdm1owIaxq8NqxfxQzAnXa+TO3VnOa9VSyomfV+q008BeAb4XWpZLbtbogrlrjDSstOAngxrlziHWuyb1oeNs+JYw6sFAAA/gLAC2H9UjFTlvpqg7NsVZpY4+dLjXvYpN4WIiLSD86yVWlibZLJq4rLnLqYYlaoKR4Bw6d9a+1r628sw6NjdDm1mezh7VjaU7osM7dDvVhP5BQqto2zbMdKerC6bQDfsfkuPh9frT3R4dWFiIh0g7NsZ0JHiCJ71lkPloFqM6DrMjN3Micr1BSfn08CeMM6NXqG6TkbGaPNTGA0xsxcdBzA123+MQBPhfUXlQVzHFw1Su3V0OQHtHLqsaY5gF/ZfNupdBGRrh0H8Km4cGR+0HLwxCU1VZIEGYD36Pl1LZ7Ix4wDXD4/zy1J5CNkVNnGXfNEVmnw1BFuqq6S5LoM34O1ce+JGjhNXVjgR7puYnWcfldHCBEZs66b8FJMVUpy6qjbqS5lE+uYcVlSXvzA+16V7dylvjpARByH7ceVUVFmjpsUu4ic+e9VSVMva2LNEl0dccoz7++KiIzFljVB3Qjg09TSscxjcUFLvKxnmZOWofhty02DaFDus6yJNdW5aMi4Feu07VvRJoD/svmTdnOAqK9tN5TMXCv7FkfVXWSg6hac8lAhcUwfv2drChwpH8WVIiIjNrMLVj7GxSnVsRU5fytOqTMldVt8lo3/tZ1zAp6CKvdj5WHP8rJOmwXLuzCEzBzvW0dV9q28O0BsUhvt+ZxbcLRtRldC5ytcZc3pCvJMTgHlX8X/ZItesM/ough0RUS6cNY6dqXKvK3i/g6yJH9C86dovgjfQnIvJ0vyZQA/C8umgO9W8ArNs+tp/n2ad59v0PlgnfC+daLKvpUXzH2O5l+vkGZeVd0fkBdOwnrERPcB+Pe4sEX8GT9P8yIi62Bot1A6nfACnd1G8y/RfJG/pPl4a0pPUsTbhE0B34/1NZpn3MPU72vLtuhWmlNUtm/N8/atvGDO22jRUWRc9wfE92/9Oc3DdoDDnGxdm/gz8k4r7cly0soiU9LnWJbnBnYi9ZEOUuPj+f/SfBEedSGOpvAogG/lZFTWHd+P9XTF//+r4fmWNVsva6VbZ2X71naVfYtrBo5y6tFSqFsvxwMBssx2gCrvsYo4GGLqvzc1G/Y9drHviQzVQcWe/akU9XStUkvWVPxbPnWRlatbLwfaRrG2a8POa1O8IOXzc1G9HMJ5NB7rD3ru4TqEmrmV9y3uZr3o4OqwyQ9oRh00/PPNOt4B/DMfJegaP2W+/3X1PYoMVWbHtIMqB+4EphbMNRlixDvE8cj8frKd6kU+7zfLasr9tRw07eYEMF0bQjC38r7FY+wcxJUJcGBWJyjy/9ShffGLjgMA3mGr/vClnPduqrMfSHvm9h3s2HTc9nPt3/3J7BjXR4ZuasGcnzzrtgps27/xwLvyyXZNeQxRJX7I6PX7tu32erp4YUMI5mB/v/G+xUN+dHUAmdX5gMFGzR9eW7j7PkfO0owPJ9PFQVvyxROoT31fJY/dfMULFG+OKmuySmFqwRxsWzdpjcrsPNT0PLZu6p6Tffs12fYpDCWYwyr7Fv+AVjkArTtOyR8NaCccqwM7SfR9RTZlM7o44jrWIRzQxmqTWh5W4SeXZc1WbZpiMCeCgQVzjXgzl091o+sp0bZqj/9wumwml3J8Ite+XZ8PeMrHiFUddnzBEz+/TwrmZN2NvnabR21eNEnrTQwfbJTFbMY7wKipelh435ZyM7sg2Q8BEJestLEd/QTTVfmLgjmZqsx+011dOLWCx5njQfww8TFequCxj3jEa6nuUXt8PCyX/nAmbkhjjRXZ67j5MboKwB02/4bdqeAYgEfC61a1Z8ech1TWIZLUObvbSOk4bkMWryqlHG8vFYnX54XdKa/0pT5v9j4aQc2I70NDzNzEUow2+HfTRXZOmTmREeHMHI843NWI22PGtznjW5JJNd40fSIsl355lgk5I7MPzVX2+JGwfF39xB6VnRORS3Aw5ze7R+Krr3XxW5q/Zmzt6z3L7IQEAD8O66RffO/jlLfFk/rOUtM334hbRCbOg7l4lad6ueU+CM+vD8+l2J32eF772qCMrV5uip63xwfDchGZMA/mPhqWy3K/Ds+9yUeW+4I9ngrLpV+fpfkXaV6Gw28Af0wjDoiI42ZWFgMVWe7muEAK3WWPL4XldWxYL8ZlJzQfDHfLHtUcXqxOvdxc27QXnMn+DM2LyIR5MMdX5ADwYXgul9M2ambDagzR8KLBb0D+NIC/BfAr63kXA4pNe90pG/rkNgA/APCe9QaMr5dq9XKbNi7gs7ZNnwbwWk6phqTjTeAaEklELsHDERxVyHbIBbzNur534ljx4NRNAqq9MDQD36gZ9p67FsjFuxd4IMivlwt4KI2ibRO369y+j77uq+ufuejz9inF0CTO7w2dcrBtDU0iMiJFzaxSH/cGlmI+OPX5BoMyblgT7TdpmfcqvtuCi3+z55/OyS6dA/Btm787J9ibsmX1ch5A32PbNbNm8vss0zqV4UGGwDtf6ZgjIgAFczfSMvUwHKZ4e6AuphSDR3/KHl8Py6v4axuXrigI/KkN3/BwXEHepflYXjBlXC/3Fs2DArmHadvfRM3lAPA+zUta79C8LkhEpHBoEhmeU1Yr0+WUordpk6ZVtwXg52HZJ8NzztpJdVwv9xrNcyDH3rYLP9gg418P6yUdviAREbmI6yNS1kSsG85iqa6jGt9edeuc/NZN0YLes0qWYky3q+oK13dxNna3wq2jqmzzVKZaM8fv7XdSaZtq5kRGRDVz0pe8uqwyNwF4LiybU1PfmZwauTycyYvNiVPFzc2nLHvqJ9CYkYuqbHNJ5+q4QESm5wp73KdmlvMArqXXSLEFBRPPWTOglPMsxWMAngrr6toG8B2bP1Eh8ED4zo6Fe+yuYtOGSumiI8CLLWw7xr//E9bJ5Hst/40yGYCvUj1lVRmAW+2YVbcG830AzyQMRjcA/A8992NtG+Y2JA9a+h3l4X2CpTw/FGUwUx1bVxnnUmRI7vcZNbM2w9st5TAB68S3VxtNnHv0flUO9t5Um+L74s+SelqsWHsYxfc/tOEvtlr+O0X4e+lyWtaEvIqUzayg923jd5RnCs2s8e9o0jTW6UZl5lbD2+2kDdsg5Y7ssY2MAmfZrivp5eqOU6H+EwC+Edavat7Rbd3azCZxBuk0gEes2fVBGvriBIB/bjGLmSezpvQ6brbMrH/uOj5M3Gs/ZWaO37uN31GeKWTm/jwuEBkpv82fMnMNcWSc6upx3fj2WjUrwtmcqkOoHNK/0cDYF5R1CNmkDiaLAW4zdYC4/DtryxQycyJrQx0gxsPvMdrllGLIGh/OYtX35vtSVhlCZU6ZpjOJszJjUnY/1heoDvEaAE+G9dI/deIRkYuUmWumy6tHHoKjqynFvuD72qrZFK5R24wrc/gtkI4Kbr1W5T3WEX/fRZa9pq9tt9HSvpSCf7ay7dYUv/dGXNkSZeZERkQ1c6vhg3Squg63CeCP4sLE3rLsTJv27BZQZwB8Iq6soW6v1EPKzMXXbwL41xU/zxhtUO1VWc0n7+ex9mtmNWt9HDP885d99r7wtkXOdlsF9+KO+3JbplAzJ7J2uG6m6Acll9PVY328rzVVt1fqJr0+r75utyBbt+7K6uXcsm293eO+P9XMXBu/oWWUmRMZkaKauaEVOsv64BqfpvtZ3Xo5zmg+S/OwXpRbAL4flk9BWb2c4965p2nefRnAz+JCScq/t5NhuYhMVFEwJ8vFAn4NQFnNb2j+YzRfx+00/980X+RGmr/Yhds8YFf+KZqqhiwLzWhFw518SPO/pHlQp5JfhOUCXB8XtMjLAd4Iy0VkojyYeycsl+U+GhdIJWetXg4APhfWVXUXzVcZ+Z97rvL8HMA/APgmLZuKP6X5sgzPm/R9RU8C+FaF8f2mZgbga2FZUTN2XRnVfr4S1onIRHkw925Y3jRjMmUfxAVSyO+xykFZVfF+rFUyaj+hgMR7/20B+Kll+aYYjHDT8/M0n+fv7fFBCyYyqzPMEg1YOzaxxuuM3WaMPZnzuiYB3p32eD5B5yQRGamiZtaPxwUdm9NYZzs2dXFboTpiM8rb4bkU+7E93trge33XarfOA/hSXFngnGWiTlgPwyMAXwDwxQmPN/eqbcOTFuyWeQHAn9l2fw/A/9m/HVoP0r48Fqav2PaKU3xdUZ1imdvsUZ0CRCQXXzFux5UdKbu/Zd2TfmqxB3DTYv6p8rsxaMgBaWrIvVlT8fEmU4/tp96sIiNSlJnjAvMuPUNXrdxz7vQAm8KupvnzE87wNPW4PcbaIhHJt2klBmfUxCojs2MXAoc5nQelZXwlNoQrIc58DXEMMN5eeeNvSbmMsgz6cUsT2YCPDyns2v+3i2y2MnPSlq3wfTapFZUlODP3Ps03KUxv2ydpfoi9trjZN2/8LSl3ju77+WhYJ1LFOQC3APiXuGINzQA8ZFk5BTcyJjeE501qRaWGWAPWN74X6dDq5aArjdYc2DZUdk6kmGflUt2LNVJmTtoys9arhc6V3Yi3n+mzoJ9vIZR3+6W+zcK26qLZY135d60Dtkg+PzZ3+RtRMCcyItzM+juaB4CbwvMu1b1dU9f+MDzXsCTNvWkdXu7roIeeyNhkAJ625tW/iytFRBCCubPWK9P9Mc13jXvTDrFejgdcVU/W1T1lY8D9UM2tIpf4J7vjwxcH2KNfRAaKx3nrM7U99Ho53k5TGuMqpcya1A8G+p2LdM17AfaRsVYzq8iIcSeIlD/aMkOvl0MINlXQ2Z7MTiIK6GTqtuw400cgBwVzIuMSBw3mG25f01MniLr1cn6vyK7M6N6gUDfrVp2zW0T9R881myJ9u83KTTQ4sIxV1+dmCTjr1EcvTW7CLLoqzSwj5t2dF5bN6SL45AEQF9pZRWQNKTMnTW2Ec/NhR+dmCfqum1tWLze3nWOXiuW3bFkXzbI+3tOR6uVEZE3xcZinVBewXF4TJx1nx8PLA3w8RB/Ga6HObd2LmacuLauX80COM3bHww8/Nb9B/BGA7bhSRGTk4pijcUpx3OOL5DgtlNkZBR8cOH5X/j2qvrxjWfghdTXiOOwg4X93N6zzQK5oR/EpJR4sWAcYEVk3GyVZOT72tRnQ8XG/aDrs+Fwk9e3nBGycoFGGtQdcLxG/nJS4iZfr9YoCOYRMWerPygedvMyhiMhYzC1A2rRjp99ar+p0YC0jW/Y+ecfnaMOmLfu3fPyuMnnA4O+jprthmBc0wfM583hYJx3gptYugxa+IvQfaVkgB3vddkdXbXywSx04ioikVNTJoelUpcY6/ptVpzYzhNLcbk5rGsI5s4tztASxqbWLqx9Oxx7aMu8VUxTIdSk2sXaxTUREUlEwJ22JtewoOKdLD7ggtYssFKdj92jokSEEcgifT23/IiIiF+Sdp7lzoppYe8Q9mrqIqrle7oiKbPN2kj5wujhegYiIiMjv5ZVNSU+4ODV1ezd/8TsW3PmyQ1sWiyu7onSxiIhINZt0zlRL1gBwR4gq9RBNcbDEHS4yy855UNfXcCDc5KwaDRERkWJFI1NIjzg7lyoztqz7ctdNvow7gxwm3AYiIiJjx+fMvOFKJIEr44Ic36P5r9J8m26n+Vdo3r0M4LTNHyto8k21wzxA88/ZzeBFRETkcvfS/F7OOTPVuVqWyDrIznG9XNH7czf6vGDuoGD5KrLQxKsiThERkWJlnQV9cGHpCdfO5TWDrqKoXi7igDLWzfkYcG3bob+pWjkREZFiyzoLHi8YXFg6lCo7t6xezvlr8oK27QQdNDgrp1o5ERGRcpwAyTufLxK0oElN3Amhzciae73ElCzz1+R1cz5M0GOGd8qyzyUiIiKXjvwQg7atgvO39IC/qNjU2ZS/39GS7JcHfXFn2CxI566Cb93VdsZPRGSIMjvG52VU+rBln2ffpuMJLtqlXZwEYd7S1VbcICvipsey+raqONu37P38tdzV2Ysp4xXAqryzxaE6PYjIRPDtl8ourFOb27F3z0poNuzRj8sLtZYM1oxiBD93zuz8rkB8YDgAW7VTAGfAqvw4PQt3aD/sFD9qruHTziciU+Gj9veZmfNgoOi4zq1DOj4PU955Wt/VQPEV3KqZq1mD95gnyMYhXFX0eUATEZmiPWuqK8MZurrnDunORqLztLTMx5Jpu16tT/5/2u+5mUFEZIo8SVAW0PFQWau2DolMHtfPtdm7tS+ebTxUkaaISOeq3raRX6cWFJEWeAeEsV8h+ZWeetuIyNR42coQWiO8CbUsM8fBXNnrRKQGTnkXFa0OmY9YrSJNEZkSH4pk32rVxnIMVCc1keCKuKChLQA/svlbALwZ1g/VHMBLNv+wxpQTkQnZs+Pfd+35EYDzAK4Nr4MdK/8RwEfiihU8T3+7jgMAt9pn/YOcG7mLTM6VcUFDewDut/mXRtLDSIGciEzVhgVmHkx5eck19Br2sZYDOQC4Oi6oYNMCOQD4GwVyImlsWKp+DPcyXYyoWUFEpE17oSzGO4DFO+wMCddo67gtIiIikxY7rA09SMqseVUX4CIiIiIB9+YfIg/kNGyUiIiISA4fDmSI44V6IKeB3EVKtNWbVURExmcG4IzNl41EkAG4KS5c0e8AnI0LSWZB3IF1Uos2AXy8YY9YERERkbXgHR8OaNksPEcY262tqayzhWfkYm0fO75kvchkKDMnIjJdhwCO2dBSPjyT31XhKXodrF7tqrBsFW8XDC3iGblvlwwZlQF4DcCXALwcV4qIiIhMhWfJvGNB1vPQUnP7+zGLVzT19TlFREREBsE7P8xtOujxtowZDZFSdRIRNbOKiExaBuABAHcAeB/AMz02W84A3BsXlninpBlWZFL+HxQ5Hksm5vWKAAAAAElFTkSuQmCC)

It's easy to show that each denominator _i_ will divide the product so far, so the exact division algorithm is used (see Section 15.2.5 \[Exact Division\], page 104).

The numerators _n_ − _k_ \+ _i_ and denominators _i_ are first accumulated into as many fit a limb, to save multi-precision operations, though for mpz*bin_ui this applies only to the divisors, since \_n* is an mpz*t and \_n* − _k_ \+ _i_ in general won't fit in a limb at all.

### 15.7.4 Fibonacci Numbers

The Fibonacci functions mpz*fib_ui and mpz_fib2_ui are designed for calculating isolated \_F<sub>n</sub>* or _F<sub>n</sub>_,_F<sub>n</sub>_<sub>−1</sub> values efficiently.

For small _n_, a table of single limb values in \__gmp_fib_table is used. On a 32-bit limb this goes up to \_F_<sub>47</sub>, or on a 64-bit limb up to _F_<sub>93</sub>. For convenience the table starts at _F_<sub>−1</sub>.

Beyond the table, values are generated with a binary powering algorithm, calculating a pair _F<sub>n</sub>_ and _F<sub>n</sub>_<sub>−1</sub> working from high to low across the bits of _n_. The formulas used are

_F_2_k_+1 = 4*Fk_2 − \_Fk_2−1 + 2(−1)\_k*

*F_2_k*−1 = \_Fk_2 + \_Fk_2−1

_F_2_k_ \= _F_2_k_+1 − *F_2_k*−1

At each step, _k_ is the high _b_ bits of _n_. If the next bit of _n_ is 0 then _F_<sub>2</sub>_<sub>k</sub>_,_F_<sub>2</sub>_<sub>k</sub>_<sub>−1</sub> is used, or if it's a 1 then _F_<sub>2</sub>_<sub>k</sub>_<sub>+1</sub>,_F_<sub>2</sub>_<sub>k</sub>_ is used, and the process repeated until all bits of _n_ are incorporated. Notice these formulas require just two squares per bit of _n_.

It'd be possible to handle the first few _n_ above the single limb table with simple additions, using the defining Fibonacci recurrence _F<sub>k</sub>_<sub>+1</sub> \= _F<sub>k</sub>_ \+ _F<sub>k</sub>_<sub>−1</sub>, but this is not done since it usually turns out to be faster for only about 10 or 20 values of _n_, and including a block of code for just those doesn't seem worthwhile. If they really mattered it'd be better to extend the data table.

Using a table avoids lots of calculations on small numbers, and makes small _n_ go fast. A bigger table would make more small _n_ go fast, it's just a question of balancing size against desired speed. For GMP the code is kept compact, with the emphasis primarily on a good powering algorithm.

mpz*fib2_ui returns both \_F<sub>n</sub>* and _F<sub>n</sub>_<sub>−1</sub>, but mpz*fib_ui is only interested in \_F<sub>n</sub>*. In this case the last step of the algorithm can become one multiply instead of two squares. One of the following two formulas is used, according as _n_ is odd or even.

_F_2_k_ \= _Fk_(_Fk_ \+ 2*Fk*−1)

_F_2_k_+1 = (2*Fk* \+ *Fk*−1)(2*Fk* − *Fk*−1) + 2(−1)_k_

_F_<sub>2</sub>_<sub>k</sub>_<sub>+1</sub> here is the same as above, just rearranged to be a multiply. For interest, the 2(−1)_<sup>k</sup>_ term both here and above can be applied just to the low limb of the calculation, without a carry or borrow into further limbs, which saves some code size. See comments with mpz_fib_ui and the internal mpn_fib2_ui for how this is done.

### 15.7.5 Lucas Numbers

mpz_lucnum2_ui derives a pair of Lucas numbers from a pair of Fibonacci numbers with the following simple formulas.

_Lk_ \= _Fk_ \+ 2*Fk*−1

*Lk*−1 = 2*Fk* − *Fk*−1

mpz*lucnum_ui is only interested in \_L<sub>n</sub>*, and some work can be saved. Trailing zero bits on _n_ can be handled with a single square each.

_L_2_k_ \= _L_2_k_ − 2(−1)_k_

And the lowest 1 bit can be handled with one multiply of a pair of Fibonacci numbers, similar to what mpz_fib_ui does.

_L_2_k_+1 = 5*Fk*−1(2*Fk* \+ *Fk*−1) − 4(−1)_k_

### 15.7.6 Random Numbers

For the urandomb functions, random numbers are generated simply by concatenating bits produced by the generator. As long as the generator has good randomness properties this will produce well-distributed _N_ bit numbers.

For the urandomm functions, random numbers in a range 0 ≤ _R < N_ are generated by taking values _R_ of dlog<sub>2</sub> _N_e bits each until one satisfies \_R < N_. This will normally require only one or two attempts, but the attempts are limited in case the generator is somehow degenerate and produces only 1 bits or similar.

The Mersenne Twister generator is by Matsumoto and Nishimura (see Appendix B \[References\], page 130). It has a non-repeating period of 2<sup>19937</sup>−1, which is a Mersenne prime, hence the name of the generator. The state is 624 words of 32-bits each, which is iterated with one XOR and shift for each 32-bit word generated, making the algorithm very fast. Randomness properties are also very good and this is the default algorithm used by GMP.

Linear congruential generators are described in many text books, for instance Knuth volume 2 (see Appendix B \[References\], page 130). With a modulus _M_ and parameters _A_ and _C_, an integer state _S_ is iterated by the formula _S_ ← _AS_ \+ _C_ mod _M_. At each step the new state is a linear function of the previous, mod _M_, hence the name of the generator.

In GMP only moduli of the form 2*<sup>N</sup>* are supported, and the current implementation is not as well optimized as it could be. Overheads are significant when _N_ is small, and when _N_ is large clearly the multiply at each step will become slow. This is not a big concern, since the Mersenne Twister generator is better in every respect and is therefore recommended for all normal applications.

For both generators the current state can be deduced by observing enough output and applying some linear algebra (over GF(2) in the case of the Mersenne Twister). This generally means raw output is unsuitable for cryptographic applications without further hashing or the like.

## 15.8 Assembly Coding

The assembly subroutines in GMP are the most significant source of speed at small to moderate sizes. At larger sizes algorithm selection becomes more important, but of course speedups in low level routines will still speed up everything proportionally.

Carry handling and widening multiplies that are important for GMP can't be easily expressed in C. GCC asm blocks help a lot and are provided in longlong.h, but hand coding low level routines invariably offers a speedup over generic C by a factor of anything from 2 to 10.

### 15.8.1 Code Organisation

The various mpn subdirectories contain machine-dependent code, written in C or assembly. The mpn/generic subdirectory contains default code, used when there's no machine-specific version of a particular file.

Each mpn subdirectory is for an ISA family. Generally 32-bit and 64-bit variants in a family cannot share code and have separate directories. Within a family further subdirectories may exist for CPU variants.

In each directory a nails subdirectory may exist, holding code with nails support for that CPU variant. A NAILS_SUPPORT directive in each file indicates the nails values the code handles. Nails code only exists where it's faster, or promises to be faster, than plain code. There's no effort put into nails if they're not going to enhance a given CPU.

### 15.8.2 Assembly Basics

mpn_addmul_1 and mpn_submul_1 are the most important routines for overall GMP performance. All multiplications and divisions come down to repeated calls to these. mpn_add_n, mpn_sub_n, mpn_lshift and mpn_rshift are next most important.

On some CPUs assembly versions of the internal functions mpn*mul_basecase and mpn_sqr* basecase give significant speedups, mainly through avoiding function call overheads. They can also potentially make better use of a wide superscalar processor, as can bigger primitives like mpn_addmul_2 or mpn_addmul_4.

The restrictions on overlaps between sources and destinations (see Chapter 8 \[Low-level Functions\], page 60) are designed to facilitate a variety of implementations. For example, knowing mpn_add_n won't have partly overlapping sources and destination means reading can be done far ahead of writing on superscalar processors, and loops can be vectorized on a vector processor, depending on the carry handling.

### 15.8.3 Carry Propagation

The problem that presents most challenges in GMP is propagating carries from one limb to the next. In functions like mpn_addmul_1 and mpn_add_n, carries are the only dependencies between limb operations.

On processors with carry flags, a straightforward CISC style adc is generally best. AMD K6 mpn_addmul_1 however is an example of an unusual set of circumstances where a branch works out better.

On RISC processors generally an add and compare for overflow is used. This sort of thing can be seen in mpn/generic/aors_n.c. Some carry propagation schemes require 4 instructions, meaning at least 4 cycles per limb, but other schemes may use just 1 or 2. On wide superscalar processors performance may be completely determined by the number of dependent instructions between carry-in and carry-out for each limb.

On vector processors good use can be made of the fact that a carry bit only very rarely propagates more than one limb. When adding a single bit to a limb, there's only a carry out if that limb was 0xFF...FF which on random data will be only 1 in 2<sup>mp bits per limb</sup>. mpn/cray/add_n.c is an example of this, it adds all limbs in parallel, adds one set of carry bits in parallel and then only rarely needs to fall through to a loop propagating further carries.

On the x86s, GCC (as of version 2.95.2) doesn't generate particularly good code for the RISC style idioms that are necessary to handle carry bits in C. Often conditional jumps are generated where adc or sbb forms would be better. And so unfortunately almost any loop involving carry bits needs to be coded in assembly for best results.

### 15.8.4 Cache Handling

GMP aims to perform well both on operands that fit entirely in L1 cache and those which don't.

Basic routines like mpn_add_n or mpn_lshift are often used on large operands, so L2 and main memory performance is important for them. mpn_mul_1 and mpn_addmul_1 are mostly used for multiply and square basecases, so L1 performance matters most for them, unless assembly versions of mpn_mul_basecase and mpn_sqr_basecase exist, in which case the remaining uses are mostly for larger operands.

For L2 or main memory operands, memory access times will almost certainly be more than the calculation time. The aim therefore is to maximize memory throughput, by starting a load of the next cache line while processing the contents of the previous one. Clearly this is only possible if the chip has a lock-up free cache or some sort of prefetch instruction. Most current chips have both these features.

Prefetching sources combines well with loop unrolling, since a prefetch can be initiated once per unrolled loop (or more than once if the loop covers more than one cache line).

On CPUs without write-allocate caches, prefetching destinations will ensure individual stores don't go further down the cache hierarchy, limiting bandwidth. Of course for calculations which are slow anyway, like mpn_divrem_1, write-throughs might be fine.

The distance ahead to prefetch will be determined by memory latency versus throughput. The aim of course is to have data arriving continuously, at peak throughput. Some CPUs have limits on the number of fetches or prefetches in progress.

If a special prefetch instruction doesn't exist then a plain load can be used, but in that case care must be taken not to attempt to read past the end of an operand, since that might produce a segmentation violation.

Some CPUs or systems have hardware that detects sequential memory accesses and initiates suitable cache movements automatically, making life easy.

### 15.8.5 Functional Units

When choosing an approach for an assembly loop, consideration is given to what operations can execute simultaneously and what throughput can thereby be achieved. In some cases an algorithm can be tweaked to accommodate available resources.

Loop control will generally require a counter and pointer updates, costing as much as 5 instructions, plus any delays a branch introduces. CPU addressing modes might reduce pointer updates, perhaps by allowing just one updating pointer and others expressed as offsets from it, or on CISC chips with all addressing done with the loop counter as a scaled index.

The final loop control cost can be amortised by processing several limbs in each iteration (see Section 15.8.9 \[Assembly Loop Unrolling\], page 120). This at least ensures loop control isn't a big fraction of the work done.

Memory throughput is always a limit. If perhaps only one load or one store can be done per cycle then 3 cycles/limb will be the top speed for "binary" operations like mpn_add_n, and any code achieving that is optimal.

Integer resources can be freed up by having the loop counter in a float register, or by pressing the float units into use for some multiplying, perhaps doing every second limb on the float side (see Section 15.8.6 \[Assembly Floating Point\], page 118).

Float resources can be freed up by doing carry propagation on the integer side, or even by doing integer to float conversions in integers using bit twiddling.

### 15.8.6 Floating Point

Floating point arithmetic is used in GMP for multiplications on CPUs with poor integer multipliers. It's mostly useful for mpn_mul_1, mpn_addmul_1 and mpn_submul_1 on 64-bit machines, and mpn_mul_basecase on both 32-bit and 64-bit machines.

With IEEE 53-bit double precision floats, integer multiplications producing up to 53 bits will give exact results. Breaking a 64×64 multiplication into eight 16×32 → 48 bit pieces is convenient. With some care though six 21×32 → 53 bit products can be used, if one of the lower two 21-bit pieces also uses the sign bit.

For the mpn_mul_1 family of functions on a 64-bit machine, the invariant single limb is split at the start, into 3 or 4 pieces. Inside the loop, the bignum operand is split into 32-bit pieces. Fast conversion of these unsigned 32-bit pieces to floating point is highly machine-dependent. In some cases, reading the data into the integer unit, zero-extending to 64-bits, then transferring to the floating point unit back via memory is the only option.

Converting partial products back to 64-bit limbs is usually best done as a signed conversion. Since all values are smaller than 2<sup>53</sup>, signed and unsigned are the same, but most processors lack unsigned conversions.

Here is a diagram showing 16×32 bit products for an mpn_mul_1 or mpn_addmul_1 with a 64-bit limb. The single limb operand V is split into four 16-bit parts. The multi-limb operand U is split in the loop into two 32-bit parts.

| \_v_48 | \_v_32 | \_v_16 | \_v_00 |
| ------ | ------ | ------ | ------ |
|        |        |        |        |
| \_u_32 |        | \_u_00 |        |

V Operand

×U Operand (one limb)

\_u_00 × \_v_00 \_p_00 48-bit products

\_u_00 × \_v_16 \_p_16 \_u_00 × \_v_32 \_p_32 \_u_00 × \_v_48 \_p_48 \_u_32 × \_v_00 \_r_32 \_u_32 × \_v_16 \_r_48 \_u_32 × \_v_32 \_r_64 \_u_32 × \_v_48 \_r_80

\_p_32 and \_r_32 can be summed using floating-point addition, and likewise \_p_48 and \_r_48\. \_p_00 and \_p_16 can be summed with \_r_64 and \_r_80 from the previous iteration.

For each loop then, four 49-bit quantities are transferred to the integer unit, aligned as follows,

64 bits 64 bits

\_p_00 + \_r_64<sup>0</sup>

\_p_16 + \_r_80<sup>0</sup>

\_p_32 + \_r_32

\_p_48 + \_r_48

\_i_00 \_i_16 \_i_32 \_i_48

The challenge then is to sum these efficiently and add in a carry limb, generating a low 64-bit result limb and a high 33-bit carry limb (\_i_48 extends 33 bits into the high half).

### 15.8.7 SIMD Instructions

The single-instruction multiple-data support in current microprocessors is aimed at signal processing algorithms where each data point can be treated more or less independently. There's generally not much support for propagating the sort of carries that arise in GMP.

SIMD multiplications of say four 16×16 bit multiplies only do as much work as one 32×32 from GMP's point of view, and need some shifts and adds besides. But of course if say the SIMD form is fully pipelined and uses less instruction decoding then it may still be worthwhile.

On the x86 chips, MMX has so far found a use in mpn_rshift and mpn_lshift, and is used in a special case for 16-bit multipliers in the P55 mpn_mul_1. SSE2 is used for Pentium 4 mpn_mul_1, mpn_addmul_1, and mpn_submul_1.

### 15.8.8 Software Pipelining

Software pipelining consists of scheduling instructions around the branch point in a loop. For example a loop might issue a load not for use in the present iteration but the next, thereby allowing extra cycles for the data to arrive from memory.

Naturally this is wanted only when doing things like loads or multiplies that take several cycles to complete, and only where a CPU has multiple functional units so that other work can be done in the meantime.

A pipeline with several stages will have a data value in progress at each stage and each loop iteration moves them along one stage. This is like juggling.

If the latency of some instruction is greater than the loop time then it will be necessary to unroll, so one register has a result ready to use while another (or multiple others) are still in progress (see Section 15.8.9 \[Assembly Loop Unrolling\], page 120).

### 15.8.9 Loop Unrolling

Loop unrolling consists of replicating code so that several limbs are processed in each loop. At a minimum this reduces loop overheads by a corresponding factor, but it can also allow better register usage, for example alternately using one register combination and then another. Judicious use of m4 macros can help avoid lots of duplication in the source code.

Any amount of unrolling can be handled with a loop counter that's decremented by _N_ each time, stopping when the remaining count is less than the further _N_ the loop will process. Or by subtracting _N_ at the start, the termination condition becomes when the counter _C_ is less than 0 (and the count of remaining limbs is _C_ \+ _N_).

Alternately for a power of 2 unroll the loop count and remainder can be established with a shift and mask. This is convenient if also making a computed jump into the middle of a large loop.

The limbs not a multiple of the unrolling can be handled in various ways, for example

- A simple loop at the end (or the start) to process the excess. Care will be wanted that it isn't too much slower than the unrolled part.
- A set of binary tests, for example after an 8-limb unrolling, test for 4 more limbs to process, then a further 2 more or not, and finally 1 more or not. This will probably take more code space than a simple loop.
- A switch statement, providing separate code for each possible excess, for example an 8-limb unrolling would have separate code for 0 remaining, 1 remaining, etc, up to 7 remaining. This might take a lot of code, but may be the best way to optimize all cases in combination with a deep pipelined loop.
- A computed jump into the middle of the loop, thus making the first iteration handle the excess. This should make times smoothly increase with size, which is attractive, but setups for the jump and adjustments for pointers can be tricky and could become quite difficult in combination with deep pipelining.

### 15.8.10 Writing Guide

This is a guide to writing software pipelined loops for processing limb vectors in assembly.

First determine the algorithm and which instructions are needed. Code it without unrolling or scheduling, to make sure it works. On a 3-operand CPU try to write each new value to a new register, this will greatly simplify later steps.

Then note for each instruction the functional unit and/or issue port requirements. If an instruction can use either of two units, like U0 or U1 then make a category "U0/U1". Count the total using each unit (or combined unit), and count all instructions.

Figure out from those counts the best possible loop time. The goal will be to find a perfect schedule where instruction latencies are completely hidden. The total instruction count might be the limiting factor, or perhaps a particular functional unit. It might be possible to tweak the instructions to help the limiting factor.

Suppose the loop time is _N_, then make _N_ issue buckets, with the final loop branch at the end of the last. Now fill the buckets with dummy instructions using the functional units desired. Run this to make sure the intended speed is reached.

Now replace the dummy instructions with the real instructions from the slow but correct loop you started with. The first will typically be a load instruction. Then the instruction using that value is placed in a bucket an appropriate distance down. Run the loop again, to check it still runs at target speed.

Keep placing instructions, frequently measuring the loop. After a few you will need to wrap around from the last bucket back to the top of the loop. If you used the new-register for newvalue strategy above then there will be no register conflicts. If not then take care not to clobber something already in use. Changing registers at this time is very error prone.

The loop will overlap two or more of the original loop iterations, and the computation of one vector element result will be started in one iteration of the new loop, and completed one or several iterations later.

The final step is to create feed-in and wind-down code for the loop. A good way to do this is to make a copy (or copies) of the loop at the start and delete those instructions which don't have valid antecedents, and at the end replicate and delete those whose results are unwanted (including any further loads).

The loop will have a minimum number of limbs loaded and processed, so the feed-in code must test if the request size is smaller and skip either to a suitable part of the wind-down or to special code for small sizes.

# 16 Internals

This chapter is provided only for informational purposes and the various internals described here may change in future GMP releases. Applications expecting to be compatible with future releases should use only the documented interfaces described in previous chapters.

## 16.1 Integer Internals

mpz_t variables represent integers using sign and magnitude, in space dynamically allocated and reallocated. The fields are as follows.

\_mp_size The number of limbs, or the negative of that when representing a negative integer. Zero is represented by \_mp_size set to zero, in which case the \_mp_d data is undefined.

\_mp_d A pointer to an array of limbs which is the magnitude. These are stored "little endian" as per the mpn functions, so \_mp_d\[0\] is the least significant limb and \_mp_d\[ABS(\_mp_size)-1\] is the most significant. Whenever \_mp_size is non-zero, the most significant limb is non-zero.

Currently there's always at least one readable limb, so for instance mpz_get_ui can fetch \_mp_d\[0\] unconditionally (though its value is undefined if \_mp_size is zero).

\_mp_alloc

\_mp_alloc is the number of limbs currently allocated at \_mp_d, and normally \_mp_alloc>=ABS(\_mp_size). When an mpz routine is about to (or might be about to) increase \_mp_size, it checks \_mp_alloc to see whether there's enough space, and reallocates if not. MPZ_REALLOC is generally used for this.

mpz_t variables initialised with the mpz_roinit_n function or the MPZ_ROINIT_N macro have \_mp_alloc=0 but can have a non-zero \_mp_size. They can only be used as read-only constants. See Section 5.16 \[Integer Special Functions\], page 45 for details.

The various bitwise logical functions like mpz_and behave as if negative values were two's complement. But sign and magnitude is always used internally, and necessary adjustments are made during the calculations. Sometimes this isn't pretty, but sign and magnitude are best for other routines.

Some internal temporary variables are set up with MPZ_TMP_INIT and these have \_mp_d space obtained from TMP_ALLOC rather than the memory allocation functions. Care is taken to ensure that these are big enough that no reallocation is necessary (since it would have unpredictable consequences).

\_mp_size and \_mp_alloc are int, although mp_size_t is usually a long. This is done to make the fields just 32 bits on some 64 bits systems, thereby saving a few bytes of data space but still providing plenty of range.

## 16.2 Rational Internals

mpq_t variables represent rationals using an mpz_t numerator and denominator (see Section 16.1 \[Integer Internals\], page 122).

The canonical form adopted is denominator positive (and non-zero), no common factors between numerator and denominator, and zero uniquely represented as 0/1.

It's believed that casting out common factors at each stage of a calculation is best in general. A GCD is an _O_(_N_<sup>2</sup>) operation so it's better to do a few small ones immediately than to delay and

have to do a big one later. Knowing the numerator and denominator have no common factors can be used for example in mpq_mul to make only two cross GCDs necessary, not four.

This general approach to common factors is badly sub-optimal in the presence of simple factorizations or little prospect for cancellation, but GMP has no way to know when this will occur. As per Section 3.11 \[Efficiency\], page 23, that's left to applications. The mpq_t framework might still suit, with mpq_numref and mpq_denref for direct access to the numerator and denominator, or of course mpz_t variables can be used directly.

## 16.3 Float Internals

Efficient calculation is the primary aim of GMP floats and the use of whole limbs and simple rounding facilitates this.

mpf_t floats have a variable precision mantissa and a single machine word signed exponent. The mantissa is represented using sign and magnitude.

most significant limb least significant limb mp exp → mp d

· ← radix point

← mp size →

The fields are as follows.

| \_mp_size | The number of limbs currently in use, or the negative of that when representing a negative value. Zero is represented by \_mp_size and \_mp_exp both set to zero, and in that case the \_mp_d data is unused. (In the future \_mp_exp might be undefined when representing zero.)                                                                                                                                                                                                                                                                                                                                       |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| \_mp_prec | The precision of the mantissa, in limbs. In any calculation the aim is to produce \_mp_prec limbs of result (the most significant being non-zero).                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| \_mp_d    | A pointer to the array of limbs which is the absolute value of the mantissa. These are stored "little endian" as per the mpn functions, so \_mp_d\[0\] is the least significant limb and \_mp_d\[ABS(\_mp_size)-1\] the most significant.<br><br>The most significant limb is always non-zero, but there are no other restrictions on its value, in particular the highest 1 bit can be anywhere within the limb.<br><br>\_mp_prec+1 limbs are allocated to \_mp_d, the extra limb being for convenience (see below). There are no reallocations during a calculation, only in a change of precision with mpf_set_prec. |
| \_mp_exp  | The exponent, in limbs, determining the location of the implied radix point. Zero means the radix point is just above the most significant limb. Positive values mean a radix point offset towards the lower limbs and hence a value ≥ 1, as for example in the diagram above. Negative exponents mean a radix point further above the highest limb.<br><br>Naturally the exponent can be any value, it doesn't have to fall within the limbs as the diagram shows, it can be a long way above or a long way below. Limbs other than those included in the {\_mp_d,\_mp_size} data are treated as zero.                 |

The \_mp_size and \_mp_prec fields are int, although the mp_size_t type is usually a long. The \_mp_exp field is usually long. This is done to make some fields just 32 bits on some 64 bits systems, thereby saving a few bytes of data space but still providing plenty of precision and a very large range.

The following various points should be noted.

Low Zeros The least significant limbs \_mp_d\[0\] etc can be zero, though such low zeros can always be ignored. Routines likely to produce low zeros check and avoid them to save time in subsequent calculations, but for most routines they're quite unlikely and aren't checked.

Mantissa Size Range

The \_mp_size count of limbs in use can be less than \_mp_prec if the value can be represented in less. This means low precision values or small integers stored in a high precision mpf_t can still be operated on efficiently.

\_mp_size can also be greater than \_mp_prec. Firstly a value is allowed to use all of the \_mp_prec+1 limbs available at \_mp_d, and secondly when mpf_set_prec_raw lowers \_mp_prec it leaves \_mp_size unchanged and so the size can be arbitrarily bigger than \_mp_prec.

| Rounding   | All rounding is done on limb boundaries. Calculating \_mp_prec limbs with the high non-zero will ensure the application requested minimum precision is obtained.<br><br>The use of simple "trunc" rounding towards zero is efficient, since there's no need to examine extra limbs and increment or decrement.                                                                                                                       |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Bit Shifts | Since the exponent is in limbs, there are no bit shifts in basic operations like mpf_add and mpf_mul. When differing exponents are encountered all that's needed is to adjust pointers to line up the relevant limbs.<br><br>Of course mpf_mul_2exp and mpf_div_2exp will require bit shifts, but the choice is between an exponent in limbs which requires shifts there, or one in bits which requires them almost everywhere else. |

Use of \_mp_prec+1 Limbs

The extra limb on \_mp_d (\_mp_prec+1 rather than just \_mp_prec) helps when an mpf routine might get a carry from its operation. mpf_add for instance will do an mpn_add of \_mp_prec limbs. If there's no carry then that's the result, but if there is a carry then it's stored in the extra limb of space and \_mp_size becomes \_mp_prec+1.

Whenever \_mp_prec+1 limbs are held in a variable, the low limb is not needed for the intended precision, only the \_mp_prec high limbs. But zeroing it out or moving the rest down is unnecessary. Subsequent routines reading the value will simply take the high limbs they need, and this will be \_mp_prec if their target has that same precision. This is no more than a pointer adjustment, and must be checked anyway since the destination precision can be different from the sources.

Copy functions like mpf*set will retain a full \_mp_prec+1 limbs if available. This ensures that a variable which has \_mp_size equal to \_mp_prec+1 will get its full exact value copied. Strictly speaking this is unnecessary since only \_mp_prec limbs are needed for the application's requested precision, but it's considered that an mpf* set from one variable into another of the same precision ought to produce an exact copy.

Application Precisions

\_\_GMPF_BITS_TO_PREC converts an application requested precision to an \_mp_prec. The value in bits is rounded up to a whole limb then an extra limb is added since the most significant limb of \_mp_d is only non-zero and therefore might contain only one bit.

\__GMPF_PREC_TO_BITS does the reverse conversion, and removes the extra limb from \_mp_prec before converting to bits. The net effect of reading back with mpf_get_ prec is simply the precision rounded up to a multiple of mp_bits_per_limb.

Note that the extra limb added here for the high only being non-zero is in addition to the extra limb allocated to \_mp_d. For example with a 32-bit limb, an application request for 250 bits will be rounded up to 8 limbs, then an extra added for the high being only non-zero, giving an \_mp_prec of 9. \_mp_d then gets 10 limbs allocated. Reading back with mpf_get_prec will take \_mp_prec subtract 1 limb and multiply by 32, giving 256 bits.

Strictly speaking, the fact that the high limb has at least one bit means that a float with, say, 3 limbs of 32-bits each will be holding at least 65 bits, but for the purposes of mpf_t it's considered simply to be 64 bits, a nice multiple of the limb size.

## 16.4 Raw Output Internals

mpz_out_raw uses the following format.

| size | data bytes |
| ---- | ---------- |

The size is 4 bytes written most significant byte first, being the number of subsequent data bytes, or the two's complement negative of that when a negative integer is represented. The data bytes are the absolute value of the integer, written most significant byte first.

The most significant data byte is always non-zero, so the output is the same on all systems, irrespective of limb size.

In GMP 1, leading zero bytes were written to pad the data bytes to a multiple of the limb size. mpz_inp_raw will still accept this, for compatibility.

The use of "big endian" for both the size and data fields is deliberate, it makes the data easy to read in a hex dump of a file. Unfortunately it also means that the limb data must be reversed when reading or writing, so neither a big endian nor little endian system can just read and write \_mp_d.

## 16.5 C++ Interface Internals

A system of expression templates is used to ensure something like a=b+c turns into a simple call to mpz_add etc. For mpf_class the scheme also ensures the precision of the final destination is used for any temporaries within a statement like f=w\*x+y\*z. These are important features which a naive implementation cannot provide.

A simplified description of the scheme follows. The true scheme is complicated by the fact that expressions have different return types. For detailed information, refer to the source code.

To perform an operation, say, addition, we first define a "function object" evaluating it,

struct \_\_gmp_binary_plus

{ static void eval(mpf_t f, const mpf_t g, const mpf_t h)

{ mpf_add(f, g, h);

}

};

And an "additive expression" object,

\_\_gmp_expr&lt;\_\_gmp_binary_expr<mpf_class, mpf_class, \_\_gmp_binary_plus&gt; > operator+(const mpf_class &f, const mpf_class &g)

{

return \_\_gmp_expr

&lt;\_\_gmp_binary_expr<mpf_class, mpf_class, \_\_gmp_binary_plus&gt; >(f, g); }

The seemingly redundant \_\_gmp_expr&lt;\_\_gmp_binary_expr<...&gt;> is used to encapsulate any possible kind of expression into a single template type. In fact even mpf_class etc are typedef specializations of \_\_gmp_expr.

Next we define assignment of \_\_gmp_expr to mpf_class.

template &lt;class T&gt; mpf_class & mpf_class::operator=(const \_\_gmp_expr&lt;T&gt; &expr)

{ expr.eval(this->get_mpf_t(), this->precision()); return \*this;

}

template &lt;class Op&gt; void \_\_gmp_expr&lt;\_\_gmp_binary_expr<mpf_class, mpf_class, Op&gt; >::eval

(mpf_t f, mp_bitcnt_t precision)

{

Op::eval(f, expr.val1.get_mpf_t(), expr.val2.get_mpf_t());

}

where expr.val1 and expr.val2 are references to the expression's operands (here expr is the \_\_gmp_binary_expr stored within the \_\_gmp_expr).

This way, the expression is actually evaluated only at the time of assignment, when the required precision (that of f) is known. Furthermore the target mpf_t is now available, thus we can call mpf_add directly with f as the output argument.

Compound expressions are handled by defining operators taking subexpressions as their arguments, like this:

template &lt;class T, class U&gt;

\_\_gmp_expr

&lt;\_\_gmp_binary_expr<\_\_gmp_expr<T&gt;, \_\_gmp_expr&lt;U&gt;, \_\_gmp_binary_plus> > operator+(const \_\_gmp_expr&lt;T&gt; &expr1, const \_\_gmp_expr&lt;U&gt; &expr2)

{ return \_\_gmp_expr

&lt;\_\_gmp_binary_expr<\_\_gmp_expr<T&gt;, \_\_gmp_expr&lt;U&gt;, \_\_gmp_binary_plus> > (expr1, expr2);

}

And the corresponding specializations of \_\_gmp_expr::eval:

template &lt;class T, class U, class Op&gt; void \_\_gmp_expr

&lt;\_\_gmp_binary_expr<\_\_gmp_expr<T&gt;, \_\_gmp_expr&lt;U&gt;, Op> >::eval

(mpf_t f, mp_bitcnt_t precision)

{

// declare two temporaries

mpf_class temp1(expr.val1, precision), temp2(expr.val2, precision); Op::eval(f, temp1.get_mpf_t(), temp2.get_mpf_t());

}

The expression is thus recursively evaluated to any level of complexity and all subexpressions are evaluated to the precision of f.

# Appendix A Contributors

Torbj¨orn Granlund wrote the original GMP library and is still the main developer. Code not explicitly attributed to others was contributed by Torbj¨orn. Several other individuals and organizations have contributed GMP. Here is a list in chronological order on first contribution:

Gunnar Sj¨odin and Hans Riesel helped with mathematical problems in early versions of the library.

Richard Stallman helped with the interface design and revised the first version of this manual.

Brian Beuning and Doug Lea helped with testing of early versions of the library and made creative suggestions.

John Amanatides of York University in Canada contributed the function mpz_probab_prime_p.

Paul Zimmermann wrote the REDC-based mpz powm code, the Sch¨onhage-Strassen FFT multiply code, and the Karatsuba square root code. He also improved the Toom3 code for GMP 4.2. Paul sparked the development of GMP 2, with his comparisons between bignum packages. The ECMNET project Paul is organizing was a driving force behind many of the optimizations in GMP 3. Paul also wrote the new GMP 4.3 nth root code (with Torbj¨orn).

Ken Weber (Kent State University, Universidade Federal do Rio Grande do Sul) contributed now defunct versions of mpz_gcd, mpz_divexact, mpn_gcd, and mpn_bdivmod, partially supported by CNPq (Brazil) grant 301314194-2.

Per Bothner of Cygnus Support helped to set up GMP to use Cygnus' configure. He has also made valuable suggestions and tested numerous intermediary releases.

Joachim Hollman was involved in the design of the mpf interface, and in the mpz design revisions for version 2.

Bennet Yee contributed the initial versions of mpz_jacobi and mpz_legendre.

Andreas Schwab contributed the files mpn/m68k/lshift.S and mpn/m68k/rshift.S (now in .asm form).

Robert Harley of Inria, France and David Seal of ARM, England, suggested clever improvements for population count. Robert also wrote highly optimized Karatsuba and 3-way Toom multiplication functions for GMP 3, and contributed the ARM assembly code.

Torsten Ekedahl of the Mathematical Department of Stockholm University provided significant inspiration during several phases of the GMP development. His mathematical expertise helped improve several algorithms.

Linus Nordberg wrote the new configure system based on autoconf and implemented the new random functions.

Kevin Ryde worked on a large number of things: optimized x86 code, m4 asm macros, parameter tuning, speed measuring, the configure system, function inlining, divisibility tests, bit scanning, Jacobi symbols, Fibonacci and Lucas number functions, printf and scanf functions, perl interface, demo expression parser, the algorithms chapter in the manual, gmpasm-mode.el, and various miscellaneous improvements elsewhere. Kent Boortz made the Mac OS 9 port.

Steve Root helped write the optimized alpha 21264 assembly code.

Gerardo Ballabio wrote the gmpxx.h C++ class interface and the C++istream input routines.

Appendix A: Contributors

Jason Moxham rewrote mpz_fac_ui.

Pedro Gimeno implemented the Mersenne Twister and made other random number improvements.

Niels M¨oller wrote the sub-quadratic GCD, extended GCD and Jacobi code, the quadratic Hensel division code, and (with Torbj¨orn) the new divide and conquer division code for GMP 4.3. Niels also helped implement the new Toom multiply code for GMP 4.3 and implemented helper functions to simplify Toom evaluations for GMP 5.0. He wrote the original version of mpn mulmod bnm1, and he is the main author of the mini-gmp package used for gmp bootstrapping.

Alberto Zanoni and Marco Bodrato suggested the unbalanced multiply strategy, and found the optimal strategies for evaluation and interpolation in Toom multiplication.

Marco Bodrato helped implement the new Toom multiply code for GMP 4.3 and implemented most of the new Toom multiply and squaring code for 5.0. He is the main author of the current mpn mulmod bnm1, mpn mullo n, and mpn sqrlo. Marco also wrote the functions mpn invert and mpn invertappr, and improved the speed of integer root extraction. He is the author of mini-mpq, an additional layer to mini-gmp; of most of the combinatorial functions and the BPSW primality testing implementation, for both the main library and the mini-gmp package.

David Harvey suggested the internal function mpn_bdiv_dbm1, implementing division relevant to Toom multiplication. He also worked on fast assembly sequences, in particular on a fast AMD64 mpn_mul_basecase. He wrote the internal middle product functions mpn_mulmid_basecase, mpn_toom42_mulmid, mpn_mulmid_n and related helper routines.

Martin Boij wrote mpn_perfect_power_p.

Marc Glisse improved gmpxx.h: use fewer temporaries (faster), specializations of numeric_limits and common_type, C++11 features (move constructors, explicit bool conversion, UDL), make the conversion from mpq_class to mpz_class explicit, optimize operations where one argument is a small compile-time constant, replace some heap allocations by stack allocations. He also fixed the eofbit handling of C++ streams, and removed one division from mpq/aors.c.

David S Miller wrote assembly code for SPARC T3 and T4.

Mark Sofroniou cleaned up the types of mul fft.c, letting it work for huge operands.

Ulrich Weigand ported GMP to the powerpc64le ABI.

(This list is chronological, not ordered after significance. If you have contributed to GMP but are not listed above, please tell <gmp-devel@gmplib.org> about the omission!)

The development of floating point functions of GNU MP 2 was supported in part by the ESPRITBRA (Basic Research Activities) 6846 project POSSO (POlynomial System SOlving).

The development of GMP 2, 3, and 4.0 was supported in part by the IDA Center for Computing Sciences.

The development of GMP 4.3, 5.0, and 5.1 was supported in part by the Swedish Foundation for Strategic Research.

Thanks go to Hans Thorsen for donating an SGI system for the GMP test system environment.

# Appendix B References

## B.1 Books

- Jonathan M. Borwein and Peter B. Borwein, "Pi and the AGM: A Study in Analytic Number Theory and Computational Complexity", Wiley, 1998.
- Richard Crandall and Carl Pomerance, "Prime Numbers: A Computational Perspective", 2nd edition, Springer-Verlag, 2005.

<https://www.math.dartmouth.edu/~carlp/>

- Henri Cohen, "A Course in Computational Algebraic Number Theory", Graduate Texts in Mathematics number 138, Springer-Verlag, 1993. <https://www.math.u-bordeaux.fr/~cohen/>
- Donald E. Knuth, "The Art of Computer Programming", volume 2, "Seminumerical Algorithms", 3rd edition, Addison-Wesley, 1998.

<https://www-cs-faculty.stanford.edu/~knuth/taocp.html>

- John D. Lipson, "Elements of Algebra and Algebraic Computing", The Benjamin Cummings Publishing Company Inc, 1981.
- Alfred J. Menezes, Paul C. van Oorschot and Scott A. Vanstone, "Handbook of Applied Cryptography", <http://www.cacr.math.uwaterloo.ca/hac/>
- Richard M. Stallman and the GCC Developer Community, "Using the GNU Compiler Collection", Free Software Foundation, 2008, available online [https://gcc.gnu.org/ onlinedocs/](https://gcc.gnu.org/onlinedocs/), and in the GCC package <https://ftp.gnu.org/gnu/gcc/>

## B.2 Papers

- Yves Bertot, Nicolas Magaud and Paul Zimmermann, "A Proof of GMP Square Root", Journal of Automated Reasoning, volume 29, 2002, pp. 225-252. Also available online as INRIA Research Report 4475, June 2002, [https://hal.inria.fr/docs/00/07/21/13/ PDF/RR-4475.pdf](https://hal.inria.fr/docs/00/07/21/13/PDF/RR-4475.pdf)
- Christoph Burnikel and Joachim Ziegler, "Fast Recursive Division", Max-Planck-Institut fuer Informatik Research Report MPI-I-98-1-022,

<https://www.mpi-inf.mpg.de/~ziegler/TechRep.ps.gz>

- Torbj¨orn Granlund and Peter L. Montgomery, "Division by Invariant Integers using Multiplication", in Proceedings of the SIGPLAN PLDI'94 Conference, June 1994. Also available <https://gmplib.org/~tege/divcnst-pldi94.pdf>.
- Niels M¨oller and Torbj¨orn Granlund, "Improved division by invariant integers", IEEE Transactions on Computers, 11 June 2010. [https://gmplib.org/~tege/division-paper.](https://gmplib.org/~tege/division-paper.pdf)

[pdf](https://gmplib.org/~tege/division-paper.pdf)

- Torbj¨orn Granlund and Niels M¨oller, "Division of integers large and small", to appear.
- Tudor Jebelean, "An algorithm for exact division", Journal of Symbolic Computation, volume 15, 1993, pp. 169-180. Research report version available

[ftp://ftp.risc.uni-linz.ac.at/pub/techreports/1992/92-35.ps.gz](ftp://ftp.risc.uni-linz.ac.at/pub/techreports/1992/92-35.ps.gz)

- Tudor Jebelean, "Exact Division with Karatsuba Complexity - Extended Abstract", RISC-

Linz technical report 96-31, [ftp://ftp.risc.uni-linz.ac.at/pub/techreports/1996/96-31.ps.gz](ftp://ftp.risc.uni-linz.ac.at/pub/techreports/1996/96-31.ps.gz)

- Tudor Jebelean, "Practical Integer Division with Karatsuba Complexity", ISSAC 97, pp.

339-341. Technical report available [ftp://ftp.risc.uni-linz.ac.at/pub/techreports/1996/96-29.ps.gz](ftp://ftp.risc.uni-linz.ac.at/pub/techreports/1996/96-29.ps.gz) Appendix B: References

- Tudor Jebelean, "A Generalization of the Binary GCD Algorithm", ISSAC 93, pp. 111-116.

Technical report version available [ftp://ftp.risc.uni-linz.ac.at/pub/techreports/1993/93-01.ps.gz](ftp://ftp.risc.uni-linz.ac.at/pub/techreports/1993/93-01.ps.gz)

- Tudor Jebelean, "A Double-Digit Lehmer-Euclid Algorithm for Finding the GCD of Long Integers", Journal of Symbolic Computation, volume 19, 1995, pp. 145-157. Technical report version also available

[ftp://ftp.risc.uni-linz.ac.at/pub/techreports/1992/92-69.ps.gz](ftp://ftp.risc.uni-linz.ac.at/pub/techreports/1992/92-69.ps.gz)

- Werner Krandick and Tudor Jebelean, "Bidirectional Exact Integer Division", Journal of Symbolic Computation, volume 21, 1996, pp. 441-455. Early technical report version also available [ftp://ftp.risc.uni-linz.ac.at/pub/techreports/1994/94-50.ps.gz](ftp://ftp.risc.uni-linz.ac.at/pub/techreports/1994/94-50.ps.gz)
- Makoto Matsumoto and Takuji Nishimura, "Mersenne Twister: A 623-dimensionally equidistributed uniform pseudorandom number generator", ACM Transactions on Modelling and Computer Simulation, volume 8, January 1998, pp. 3-30. Available online

<http://www.math.sci.hiroshima-u.ac.jp/~m-mat/MT/ARTICLES/mt.pdf>

- R. Moenck and A. Borodin, "Fast Modular Transforms via Division", Proceedings of the 13th Annual IEEE Symposium on Switching and Automata Theory, October 1972, pp. 9096. Reprinted as "Fast Modular Transforms", Journal of Computer and System Sciences, volume 8, number 3, June 1974, pp. 366-386.
- Niels M¨oller, "On Sch¨onhage's algorithm and subquadratic integer GCD computation", in Mathematics of Computation, volume 77, January 2008, pp. 589-607, [https://www.ams. org/journals/mcom/2008-77-261/S0025-5718-07-02017-0/home.html](https://www.ams.org/journals/mcom/2008-77-261/S0025-5718-07-02017-0/home.html)
- Peter L. Montgomery, "Modular Multiplication Without Trial Division", in Mathematics of Computation, volume 44, number 170, April 1985.
- Arnold Sch¨onhage and Volker Strassen, "Schnelle Multiplikation grosser Zahlen", Computing 7, 1971, pp. 281-292.
- Kenneth Weber, "The accelerated integer GCD algorithm", ACM Transactions on Mathematical Software, volume 21, number 1, March 1995, pp. 111-122.
- Paul Zimmermann, "Karatsuba Square Root", INRIA Research Report 3805, November

1999, <https://hal.inria.fr/inria-00072854/PDF/RR-3805.pdf>

- Paul Zimmermann, "A Proof of GMP Fast Division and Square Root Implementations", <https://homepages.loria.fr/PZimmermann/papers/proof-div-sqrt.ps.gz>
- Dan Zuras, "On Squaring and Multiplying Large Integers", ARITH-11: IEEE Symposium on Computer Arithmetic, 1993, pp. 260 to 271. Reprinted as "More on Multiplying and Squaring Large Integers", IEEE Transactions on Computers, volume 43, number 8, August 1994, pp. 899-908.
- Niels M¨oller, "Efficient computation of the Jacobi symbol", <https://arxiv.org/abs/1907.07795>

# Appendix C GNU Free Documentation License

Version 1.3, 3 November 2008

Copyright ![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACoAAAArCAYAAAAOnxr+AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAALiMAAC4jAXilP3YAAAK7SURBVFhH1ZlNjtQwEIUfHACEcoPAAiQk7wCJiAUSIHKCFhfoG/QNWpoT5AiouUHPLFjBqjUjsc9s2U3gBmFTNXpd7cR2fpruT4qcuJykXClX2Q5wJjywFYnkAD4AcHL+CsATkl9K+V3Of5FsdjIASwA7AK3nqAOySjo1KysADb14J3WldMBHIR3bGqWrnnsG44yVKlEglVw6ps9pACxso6EsyIq7gQpacgAb0/FRLKZ8mAc2wsYKY1mSkksrnBA3RtnySEoqrGz0l8vppmMoqRRknNIKfWgY2VrBEdCI0IRirX7yYMMenFhnJWVqlFBDra2AqaXRygoCZHKP3l/LC7fS6UbkMQFeXaDTWGrNOvKBiiMFu+KsI6WdFXrotaoGYK+wg5TQspAO1VbggV1wj4xGXEyPYaJDE/gKnDbbyFGtX6kAgIdS+VrK24SpWEVTugsAd0bOvDfXL821j29SfubKtWgfG2w55rVdTk9wKo5pD7pnx5XqvLEzmYpeuvegHkpxgRTXOnAr9YcY3wH5ZjtzYtB33Ct6UNEDD7x2QMxNQd9R6mBK4YWtmBFdc92P+pNniKK/zfVjcz0ln2zFyQ8mtaimtUfUqA9Ol8/ofEo01v4BffprKd9JGeIrnT9NiI2QZBGT759LeQvgThX9KeVHKUP84BGZuBL4AuDKVnp4K+Ve2yGTksz4asx9Rd8807A3KWHGTvNCc01tG5Ome+fGnXPAADnNFXQmzxbT3ZEmwUV6J84YsRSBWIp3P/jYBKzNBJcimGhxB1rUxSrHBK2pnMJyuY4x1P/agHDkKrEZ8jy2dJSz2CRTzmLbUWFl64Ej2ZJNvZGrOLM1nhIXGQ7+bUKmSsb3s2EtMfMg1QmF+LhNBrP8bGAyebFmMXvUgd8365gYaRn7Q8wBeCNl3vFD7C+Am7E/xP4BowInJK9+6NEAAAAASUVORK5CYII=)2000-2002, 2007, 2008 Free Software Foundation, Inc. <http://fsf.org/>

Everyone is permitted to copy and distribute verbatim copies of this license document, but changing it is not allowed.

- PREAMBLE

The purpose of this License is to make a manual, textbook, or other functional and useful document _free_ in the sense of freedom: to assure everyone the effective freedom to copy and redistribute it, with or without modifying it, either commercially or noncommercially. Secondarily, this License preserves for the author and publisher a way to get credit for their work, while not being considered responsible for modifications made by others.

This License is a kind of "copyleft", which means that derivative works of the document must themselves be free in the same sense. It complements the GNU General Public License, which is a copyleft license designed for free software.

We have designed this License in order to use it for manuals for free software, because free software needs free documentation: a free program should come with manuals providing the same freedoms that the software does. But this License is not limited to software manuals; it can be used for any textual work, regardless of subject matter or whether it is published as a printed book. We recommend this License principally for works whose purpose is instruction or reference.

- APPLICABILITY AND DEFINITIONS

This License applies to any manual or other work, in any medium, that contains a notice placed by the copyright holder saying it can be distributed under the terms of this License. Such a notice grants a world-wide, royalty-free license, unlimited in duration, to use that work under the conditions stated herein. The "Document", below, refers to any such manual or work. Any member of the public is a licensee, and is addressed as "you". You accept the license if you copy, modify or distribute the work in a way requiring permission under copyright law.

A "Modified Version" of the Document means any work containing the Document or a portion of it, either copied verbatim, or with modifications and/or translated into another language.

A "Secondary Section" is a named appendix or a front-matter section of the Document that deals exclusively with the relationship of the publishers or authors of the Document to the Document's overall subject (or to related matters) and contains nothing that could fall directly within that overall subject. (Thus, if the Document is in part a textbook of mathematics, a Secondary Section may not explain any mathematics.) The relationship could be a matter of historical connection with the subject or with related matters, or of legal, commercial, philosophical, ethical or political position regarding them.

The "Invariant Sections" are certain Secondary Sections whose titles are designated, as being those of Invariant Sections, in the notice that says that the Document is released under this License. If a section does not fit the above definition of Secondary then it is not allowed to be designated as Invariant. The Document may contain zero Invariant Sections. If the Document does not identify any Invariant Sections then there are none.

The "Cover Texts" are certain short passages of text that are listed, as Front-Cover Texts or Back-Cover Texts, in the notice that says that the Document is released under this License. A Front-Cover Text may be at most 5 words, and a Back-Cover Text may be at most 25 words.

A "Transparent" copy of the Document means a machine-readable copy, represented in a format whose specification is available to the general public, that is suitable for revising the document straightforwardly with generic text editors or (for images composed of pixels) generic paint programs or (for drawings) some widely available drawing editor, and that is suitable for input to text formatters or for automatic translation to a variety of formats suitable for input to text formatters. A copy made in an otherwise Transparent file format whose markup, or absence of markup, has been arranged to thwart or discourage subsequent modification by readers is not Transparent. An image format is not Transparent if used for any substantial amount of text. A copy that is not "Transparent" is called "Opaque".

Examples of suitable formats for Transparent copies include plain ascii without markup, Texinfo input format, LaTEX input format, SGML or XML using a publicly available DTD, and standard-conforming simple HTML, PostScript or PDF designed for human modification. Examples of transparent image formats include PNG, XCF and JPG. Opaque formats include proprietary formats that can be read and edited only by proprietary word processors, SGML or XML for which the DTD and/or processing tools are not generally available, and the machine-generated HTML, PostScript or PDF produced by some word processors for output purposes only.

The "Title Page" means, for a printed book, the title page itself, plus such following pages as are needed to hold, legibly, the material this License requires to appear in the title page. For works in formats which do not have any title page as such, "Title Page" means the text near the most prominent appearance of the work's title, preceding the beginning of the body of the text.

The "publisher" means any person or entity that distributes copies of the Document to the public.

A section "Entitled XYZ" means a named subunit of the Document whose title either is precisely XYZ or contains XYZ in parentheses following text that translates XYZ in another language. (Here XYZ stands for a specific section name mentioned below, such as "Acknowledgements", "Dedications", "Endorsements", or "History".) To "Preserve the Title" of such a section when you modify the Document means that it remains a section "Entitled XYZ" according to this definition.

The Document may include Warranty Disclaimers next to the notice which states that this License applies to the Document. These Warranty Disclaimers are considered to be included by reference in this License, but only as regards disclaiming warranties: any other implication that these Warranty Disclaimers may have is void and has no effect on the meaning of this License.

- VERBATIM COPYING

You may copy and distribute the Document in any medium, either commercially or noncommercially, provided that this License, the copyright notices, and the license notice saying this License applies to the Document are reproduced in all copies, and that you add no other conditions whatsoever to those of this License. You may not use technical measures to obstruct or control the reading or further copying of the copies you make or distribute. However, you may accept compensation in exchange for copies. If you distribute a large enough number of copies you must also follow the conditions in section 3.

You may also lend copies, under the same conditions stated above, and you may publicly display copies.

- COPYING IN QUANTITY

If you publish printed copies (or copies in media that commonly have printed covers) of the Document, numbering more than 100, and the Document's license notice requires Cover Texts, you must enclose the copies in covers that carry, clearly and legibly, all these Cover

Texts: Front-Cover Texts on the front cover, and Back-Cover Texts on the back cover. Both covers must also clearly and legibly identify you as the publisher of these copies. The front cover must present the full title with all words of the title equally prominent and visible. You may add other material on the covers in addition. Copying with changes limited to the covers, as long as they preserve the title of the Document and satisfy these conditions, can be treated as verbatim copying in other respects.

If the required texts for either cover are too voluminous to fit legibly, you should put the first ones listed (as many as fit reasonably) on the actual cover, and continue the rest onto adjacent pages.

If you publish or distribute Opaque copies of the Document numbering more than 100, you must either include a machine-readable Transparent copy along with each Opaque copy, or state in or with each Opaque copy a computer-network location from which the general network-using public has access to download using public-standard network protocols a complete Transparent copy of the Document, free of added material. If you use the latter option, you must take reasonably prudent steps, when you begin distribution of Opaque copies in quantity, to ensure that this Transparent copy will remain thus accessible at the stated location until at least one year after the last time you distribute an Opaque copy (directly or through your agents or retailers) of that edition to the public.

It is requested, but not required, that you contact the authors of the Document well before redistributing any large number of copies, to give them a chance to provide you with an updated version of the Document.

4\. MODIFICATIONS

You may copy and distribute a Modified Version of the Document under the conditions of sections 2 and 3 above, provided that you release the Modified Version under precisely this License, with the Modified Version filling the role of the Document, thus licensing distribution and modification of the Modified Version to whoever possesses a copy of it. In addition, you must do these things in the Modified Version:

- Use in the Title Page (and on the covers, if any) a title distinct from that of theDocument, and from those of previous versions (which should, if there were any, be listed in the History section of the Document). You may use the same title as a previous version if the original publisher of that version gives permission.
- List on the Title Page, as authors, one or more persons or entities responsible forauthorship of the modifications in the Modified Version, together with at least five of the principal authors of the Document (all of its principal authors, if it has fewer than five), unless they release you from this requirement.
- State on the Title page the name of the publisher of the Modified Version, as thepublisher.
- Preserve all the copyright notices of the Document.
- Add an appropriate copyright notice for your modifications adjacent to the other copy-right notices.
- Include, immediately after the copyright notices, a license notice giving the publicpermission to use the Modified Version under the terms of this License, in the form shown in the Addendum below.
- Preserve in that license notice the full lists of Invariant Sections and required CoverTexts given in the Document's license notice. H. Include an unaltered copy of this License.
- Preserve the section Entitled "History", Preserve its Title, and add to it an item statingat least the title, year, new authors, and publisher of the Modified Version as given on the Title Page. If there is no section Entitled "History" in the Document, create one stating the title, year, authors, and publisher of the Document as given on its Title Page, then add an item describing the Modified Version as stated in the previous sentence.
- Preserve the network location, if any, given in the Document for public access to aTransparent copy of the Document, and likewise the network locations given in the Document for previous versions it was based on. These may be placed in the "History" section. You may omit a network location for a work that was published at least four years before the Document itself, or if the original publisher of the version it refers to gives permission.
- For any section Entitled "Acknowledgements" or "Dedications", Preserve the Titleof the section, and preserve in the section all the substance and tone of each of the contributor acknowledgements and/or dedications given therein.
- Preserve all the Invariant Sections of the Document, unaltered in their text and in theirtitles. Section numbers or the equivalent are not considered part of the section titles.
- Delete any section Entitled "Endorsements". Such a section may not be included inthe Modified Version.
- Do not retitle any existing section to be Entitled "Endorsements" or to conflict in titlewith any Invariant Section.
- Preserve any Warranty Disclaimers.

If the Modified Version includes new front-matter sections or appendices that qualify as Secondary Sections and contain no material copied from the Document, you may at your option designate some or all of these sections as invariant. To do this, add their titles to the list of Invariant Sections in the Modified Version's license notice. These titles must be distinct from any other section titles.

You may add a section Entitled "Endorsements", provided it contains nothing but endorsements of your Modified Version by various parties-for example, statements of peer review or that the text has been approved by an organization as the authoritative definition of a standard.

You may add a passage of up to five words as a Front-Cover Text, and a passage of up to 25 words as a Back-Cover Text, to the end of the list of Cover Texts in the Modified Version. Only one passage of Front-Cover Text and one of Back-Cover Text may be added by (or through arrangements made by) any one entity. If the Document already includes a cover text for the same cover, previously added by you or by arrangement made by the same entity you are acting on behalf of, you may not add another; but you may replace the old one, on explicit permission from the previous publisher that added the old one.

The author(s) and publisher(s) of the Document do not by this License give permission to use their names for publicity for or to assert or imply endorsement of any Modified Version.

- COMBINING DOCUMENTS

You may combine the Document with other documents released under this License, under the terms defined in section 4 above for modified versions, provided that you include in the combination all of the Invariant Sections of all of the original documents, unmodified, and list them all as Invariant Sections of your combined work in its license notice, and that you preserve all their Warranty Disclaimers.

The combined work need only contain one copy of this License, and multiple identical Invariant Sections may be replaced with a single copy. If there are multiple Invariant Sections with the same name but different contents, make the title of each such section unique by adding at the end of it, in parentheses, the name of the original author or publisher of that section if known, or else a unique number. Make the same adjustment to the section titles in the list of Invariant Sections in the license notice of the combined work.

In the combination, you must combine any sections Entitled "History" in the various original documents, forming one section Entitled "History"; likewise combine any sections Entitled "Acknowledgements", and any sections Entitled "Dedications". You must delete all sections Entitled "Endorsements."

- COLLECTIONS OF DOCUMENTS

You may make a collection consisting of the Document and other documents released under this License, and replace the individual copies of this License in the various documents with a single copy that is included in the collection, provided that you follow the rules of this License for verbatim copying of each of the documents in all other respects.

You may extract a single document from such a collection, and distribute it individually under this License, provided you insert a copy of this License into the extracted document, and follow this License in all other respects regarding verbatim copying of that document.

- AGGREGATION WITH INDEPENDENT WORKS

A compilation of the Document or its derivatives with other separate and independent documents or works, in or on a volume of a storage or distribution medium, is called an "aggregate" if the copyright resulting from the compilation is not used to limit the legal rights of the compilation's users beyond what the individual works permit. When the Document is included in an aggregate, this License does not apply to the other works in the aggregate which are not themselves derivative works of the Document.

If the Cover Text requirement of section 3 is applicable to these copies of the Document, then if the Document is less than one half of the entire aggregate, the Document's Cover Texts may be placed on covers that bracket the Document within the aggregate, or the electronic equivalent of covers if the Document is in electronic form. Otherwise they must appear on printed covers that bracket the whole aggregate.

- TRANSLATION

Translation is considered a kind of modification, so you may distribute translations of the Document under the terms of section 4. Replacing Invariant Sections with translations requires special permission from their copyright holders, but you may include translations of some or all Invariant Sections in addition to the original versions of these Invariant Sections. You may include a translation of this License, and all the license notices in the Document, and any Warranty Disclaimers, provided that you also include the original English version of this License and the original versions of those notices and disclaimers. In case of a disagreement between the translation and the original version of this License or a notice or disclaimer, the original version will prevail.

If a section in the Document is Entitled "Acknowledgements", "Dedications", or "History", the requirement (section 4) to Preserve its Title (section 1) will typically require changing the actual title.

- TERMINATION

You may not copy, modify, sublicense, or distribute the Document except as expressly provided under this License. Any attempt otherwise to copy, modify, sublicense, or distribute it is void, and will automatically terminate your rights under this License.

However, if you cease all violation of this License, then your license from a particular copyright holder is reinstated (a) provisionally, unless and until the copyright holder explicitly and finally terminates your license, and (b) permanently, if the copyright holder fails to notify you of the violation by some reasonable means prior to 60 days after the cessation.

Moreover, your license from a particular copyright holder is reinstated permanently if the copyright holder notifies you of the violation by some reasonable means, this is the first time you have received notice of violation of this License (for any work) from that copyright holder, and you cure the violation prior to 30 days after your receipt of the notice.

Termination of your rights under this section does not terminate the licenses of parties who have received copies or rights from you under this License. If your rights have been terminated and not permanently reinstated, receipt of a copy of some or all of the same material does not give you any rights to use it.

- FUTURE REVISIONS OF THIS LICENSE

The Free Software Foundation may publish new, revised versions of the GNU Free Documentation License from time to time. Such new versions will be similar in spirit to the present version, but may differ in detail to address new problems or concerns. See [https:// www.gnu.org/copyleft/](https://www.gnu.org/copyleft/).

Each version of the License is given a distinguishing version number. If the Document specifies that a particular numbered version of this License "or any later version" applies to it, you have the option of following the terms and conditions either of that specified version or of any later version that has been published (not as a draft) by the Free Software Foundation. If the Document does not specify a version number of this License, you may choose any version ever published (not as a draft) by the Free Software Foundation. If the Document specifies that a proxy can decide which future versions of this License can be used, that proxy's public statement of acceptance of a version permanently authorizes you to choose that version for the Document.

- RELICENSING

"Massive Multiauthor Collaboration Site" (or "MMC Site") means any World Wide Web server that publishes copyrightable works and also provides prominent facilities for anybody to edit those works. A public wiki that anybody can edit is an example of such a server. A "Massive Multiauthor Collaboration" (or "MMC") contained in the site means any set of copyrightable works thus published on the MMC site.

"CC-BY-SA" means the Creative Commons Attribution-Share Alike 3.0 license published by Creative Commons Corporation, a not-for-profit corporation with a principal place of business in San Francisco, California, as well as future copyleft versions of that license published by that same organization.

"Incorporate" means to publish or republish a Document, in whole or in part, as part of another Document.

An MMC is "eligible for relicensing" if it is licensed under this License, and if all works that were first published under this License somewhere other than this MMC, and subsequently incorporated in whole or in part into the MMC, (1) had no cover texts or invariant sections, and (2) were thus incorporated prior to November 1, 2008.

The operator of an MMC Site may republish an MMC contained in the site under CC-BYSA on the same site at any time before August 1, 2009, provided the MMC is eligible for relicensing.

**ADDENDUM: How to use this License for your documents**

To use this License in a document you have written, include a copy of the License in the document and put the following copyright and license notices just after the title page:

Copyright (C) _year your name_.

Permission is granted to copy, distribute and/or modify this document under the terms of the GNU Free Documentation License, Version 1.3 or any later version published by the Free Software Foundation; with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts. A copy of the license is included in the section entitled ''GNU Free Documentation License''.

If you have Invariant Sections, Front-Cover Texts and Back-Cover Texts, replace the "with. . .Texts." line with this:

with the Invariant Sections being _list their titles_, with the Front-Cover Texts being _list_, and with the Back-Cover Texts being _list_.

If you have Invariant Sections without Cover Texts, or some other combination of the three, merge those two alternatives to suit the situation.

If your document contains nontrivial examples of program code, we recommend releasing these examples in parallel under your choice of free software license, such as the GNU General Public License, to permit their use in free software.

Concept Index

# Concept Index

**#**

# include _........................................_ 17

**\-**

\--build*...........................................* 3 --disable-fft*....................................* 7 --disable-shared _................................_ 3

\--disable-static _................................_ 3

\--enable-alloca _................................._ 7

\--enable-assert _................................._ 7 --enable-cxx*.....................................* 6

\--enable-fat*.....................................* 5 --enable-profiling _.........................._ 7, 27

\--exec-prefix*....................................* 3 --host*............................................* 4 --prefix _........................................._ 3

\-finstrument-functions _........................_ 28

**2**

2exp functions _..................................._ 23

**6**

68000*............................................* 13

**8**

80x86*............................................* 14

**A**

ABI _............................................_ 5, 8 About this manual _................................_ 2 AC*CHECK_LIB*....................................\_ 28

AIX*..........................................* 10, 12 Algorithms*.......................................* 96 alloca*............................................* 7 Allocation of memory _............................_ 92

AMD64*...........................................* 8 Anonymous FTP of latest version _................._ 2 Application Binary Interface*.......................* 8 Arithmetic functions*......................* 34, 48, 56

ARM _............................................_ 12

Assembly cache handling*........................* 117

Assembly carry propagation*.....................* 117

Assembly code organisation _....................._ 116 Assembly coding*................................* 116

Assembly floating point _........................._ 118

Assembly loop unrolling*.........................* 120 Assembly SIMD*.................................* 119 Assembly software pipelining*....................* 119 Assembly writing guide _........................._ 120 Assertion checking*.............................* 7, 26 Assignment functions*..................* 32, 47, 54, 55

Autoconf*.........................................* 28

**B**

Basics _..........................................._ 17

Binomial coefficient algorithm*...................* 114 Binomial coefficient functions*.....................* 39

Binutils strip _..................................._ 14

Bit manipulation functions _......................._ 40

Bit scanning functions*............................* 41

Bit shift left _....................................._ 34

Bit shift right*....................................* 35

Bits per limb*.....................................* 22

Bug reporting*....................................* 30 Build directory*....................................* 3

Build notes for binary packaging _................._ 11

Build notes for particular systems _................_ 12 Build options _....................................._ 3

Build problems known _..........................._ 14 Build system*......................................* 3

Building GMP _...................................._ 3

Bus error _........................................_ 25

**C**

C compiler*........................................* 5

C++ compiler*......................................* 6

C++ interface*.....................................* 83 C++ interface internals _.........................._ 125

C++istream input*...............................* 81

C++ostream output _............................._ 77 C++ support _......................................_ 6 CC _................................................_ 5

CC*FOR_BUILD*.....................................\_ 6

CFLAGS*............................................* 5 Checker*..........................................* 27 checkergcc _......................................_ 27 Code organisation*...............................* 116 Compaq C++_....................................._ 12

Comparison functions*.....................* 40, 49, 57

Compatibility with older versions*.................* 22 Conditions for copying GNU MP _.................._ 1

Configuring GMP _................................._ 3

Congruence algorithm*...........................* 105

Congruence functions _............................_ 36

Constants*........................................* 22

Contributors*....................................* 128 Conventions for parameters _......................_ 20

Conventions for variables*.........................* 19

Conversion functions*......................* 33, 48, 55 Copying conditions*................................* 1

CPPFLAGS _........................................._ 6

CPU types _....................................._ 2, 4

Cross compiling _..................................._ 4

Cryptography functions, low-level _................_ 67 Custom allocation*................................* 92 CXX _..............................................._ 6

CXXFLAGS _........................................._ 6

Cygwin _.........................................._ 13

**D**

Darwin _.........................................._ 15 Debugging _......................................._ 25

Demonstration programs _........................._ 22

Digits in an integer*...............................* 45 Divisibility algorithm _..........................._ 105

Divisibility functions _............................._ 36

Divisibility testing _..............................._ 24 Division algorithms _............................._ 103

Division functions*.........................* 34, 49, 56

DJGPP _......................................_ 13, 14

DLLs _............................................_ 13

DocBook*..........................................* 7

Documentation formats _..........................._ 7 Documentation license _.........................._ 132

DVI*...............................................* 7

**E**

Efficiency _........................................_ 23

Emacs _..........................................._ 29

Exact division functions*..........................* 36 Exact remainder _................................_ 105

Example programs _..............................._ 22 Exec prefix*........................................* 3

Execution profiling _............................_ 7, 27

Exponentiation functions _....................._ 36, 57

Export*...........................................* 44

Expression parsing demo _........................._ 22

Extended GCD _.................................._ 38

**F**

Factor removal functions _........................._ 39 Factorial algorithm*..............................* 113

Factorial functions _..............................._ 39

Factorization demo*...............................* 23 Fast Fourier Transform*..........................* 100

Fat binary _........................................_ 5 FFT multiplication*...........................* 7, 100

Fibonacci number algorithm _...................._ 114

Fibonacci sequence functions _....................._ 40

Float arithmetic functions*........................* 56

Float assignment functions _..................._ 54, 55

Float comparison functions*.......................* 57

Float conversion functions*........................* 55

Float functions*...................................* 52

Float initialization functions*..................* 52, 55

Float input and output functions*.................* 57 Float internals _.................................._ 123

Float miscellaneous functions*.....................* 58

Float random number functions _.................._ 59

Float rounding functions _........................._ 58

Float sign tests _.................................._ 57

Floating point mode _............................._ 12

Floating-point functions*..........................* 52 Floating-point number _..........................._ 17 fnccheck _........................................._ 28 Formatted input _................................._ 79

Formatted output*................................* 74 Free Documentation License*.....................* 132 FreeBSD*.........................................* 12 frexp _........................................_ 33, 55 FTP of latest version*..............................* 2

Function classes*..................................* 19

FunctionCheck*...................................* 28

**G**

GCC Checker*....................................* 27

GCD algorithms _................................_ 106

GCD extended*...................................* 38

GCD functions*...................................* 38

GDB _............................................_ 26 Generic C*.........................................* 5 gmp.h*............................................* 17 GMP Perl module*................................* 23 GMP version number _............................_ 22 gmpxx.h*..........................................* 83 GNU Debugger _.................................._ 26 GNU Free Documentation License*...............* 132 GNU strip*......................................* 14 gprof*............................................* 28 Greatest common divisor algorithms*.............* 106

Greatest common divisor functions _..............._ 38

**H**

Hardware floating point mode*....................* 12

Headers*..........................................* 17

Heap problems*...................................* 25

Home page*........................................* 2

Host system*.......................................* 4

HP-UX _..........................................._ 9

HPPA _............................................_ 9

**I**

i386*..............................................* 14 I/O functions*.............................* 41, 50, 57 IA-64 _............................................._ 9

Import*...........................................* 43

In-place operations*...............................* 24 Include files*......................................* 17 info-lookup-symbol*.............................* 29 Initialization functions _........._ 31, 32, 47, 52, 55, 72

Initializing and clearing _.........................._ 23

Input functions*........................* 41, 50, 57, 81 Install prefix _......................................_ 3

Installing GMP _..................................._ 3 Instruction Set Architecture*.......................* 8 instrument-functions*...........................* 28 Integer*...........................................* 17

Integer arithmetic functions _......................_ 34

Integer assignment functions _....................._ 32

Integer bit manipulation functions*................* 40

Integer comparison functions _....................._ 40

Integer conversion functions _......................_ 33

Integer division functions*.........................* 34

Integer exponentiation functions*..................* 36

Integer export*....................................* 44

Integer functions*.................................* 31

Integer import _..................................._ 43

Integer initialization functions _................_ 31, 32

Integer input and output functions _..............._ 41

Integer internals _................................_ 122

Integer logical functions*..........................* 40

Integer miscellaneous functions*...................* 44

Integer random number functions*.................* 42

Integer root functions _............................_ 37

Integer sign tests*.................................* 40

Integer special functions*..........................* 45

Concept Index

Interix _..........................................._ 13 Internals*........................................* 122

Introduction _......................................_ 2

Inverse modulo functions*.........................* 39

IRIX _.........................................._ 9, 15 ISA*...............................................* 8 istream input*....................................* 81

**J**

Jacobi symbol algorithm _........................_ 108

Jacobi symbol functions*..........................* 39

**K**

Karatsuba multiplication*.........................* 97 Karatsuba square root algorithm _................_ 110

Kronecker symbol functions _......................_ 39

**L**

Language bindings _..............................._ 94 Latest version of GMP _............................_ 2

LCM functions*...................................* 39

Least common multiple functions*.................* 39 Legendre symbol functions _......................._ 39 libgmp*...........................................* 17 libgmpxx _........................................_ 17 Libraries*.........................................* 17

Libtool _.........................................._ 17

Libtool versioning*................................* 11

License conditions*.................................* 1

Limb _............................................_ 18

Limb size _........................................_ 22 Linear congruential algorithm _..................._ 116

Linear congruential random numbers _............._ 72

Linking _.........................................._ 17

Logical functions*.................................* 40

Low-level functions*...............................* 60

Low-level functions for cryptography _............._ 67 Lucas number algorithm _........................_ 115

Lucas number functions _.........................._ 40

**M**

MacOS X*........................................* 15 Mailing lists*.......................................* 2

Malloc debugger _................................._ 25

Malloc problems _................................._ 25

Memory allocation _..............................._ 92

Memory management _............................_ 21 Mersenne twister algorithm _....................._ 115

Mersenne twister random numbers _..............._ 72

MINGW*.........................................* 13 MIPS _............................................._ 9

Miscellaneous float functions _....................._ 58

Miscellaneous integer functions*...................* 44

MMX*............................................* 14

Modular inverse functions _........................_ 39 Most significant bit _.............................._ 45

MPN*PATH *.........................................\_ 7

MS Windows _...................................._ 13

MS-DOS*.........................................* 13

Multi-threading*..................................* 21 Multiplication algorithms _........................_ 96

**N**

Nails*.............................................* 70 Native compilation _................................_ 3

NetBSD _........................................._ 13

Next prime function*..............................* 38

NeXT*............................................* 15

Nomenclature*....................................* 17 Non-Unix systems*.................................* 3

Nth root algorithm*..............................* 110 Number sequences _..............................._ 25

Number theoretic functions*.......................* 38

Numerator and denominator _....................._ 49

**O**

obstack output _.................................._ 77 OpenBSD*........................................* 13 Optimizing performance*..........................* 15 ostream output _.................................._ 77 Other languages*..................................* 94

Output functions*......................* 41, 50, 57, 76

**P**

Packaged builds*..................................* 11

Parameter conventions _..........................._ 20

Parsing expressions demo _........................_ 22

Particular systems _..............................._ 12

Past GMP versions*...............................* 22 PDF*..............................................* 7

Perfect power algorithm*.........................* 111

Perfect power functions _.........................._ 37

Perfect square algorithm _........................_ 111 Perfect square functions*..........................* 37 perl*.............................................* 23 Perl module*......................................* 23

Pointer types _...................................._ 18 Postscript*.........................................* 7

Power/PowerPC*..............................* 13, 15

Powering algorithms _............................_ 109

Powering functions _..........................._ 36, 57

PowerPC _........................................_ 10

Precision of floats _................................_ 52

Precision of hardware floating point _.............._ 12 Prefix*.............................................* 3

Previous prime function*..........................* 38

Prime testing algorithms*........................* 113 Prime testing functions*...........................* 38 Primorial functions*...............................* 39 printf formatted output*.........................* 74 Probable prime testing functions _................._ 38 prof*.............................................* 27 Profiling _........................................._ 27

**R**

Radix conversion algorithms*.....................* 111

Random number algorithms*.....................* 115 Random number functions _................_ 42, 59, 72

Random number seeding _........................._ 73

Random number state*............................* 72 Random state*....................................* 18

Rational arithmetic _.............................._ 24

Rational arithmetic functions*.....................* 48

Rational assignment functions*....................* 47

Rational comparison functions*....................* 49

Rational conversion functions*.....................* 48

Rational initialization functions _.................._ 47

Rational input and output functions*..............* 50 Rational internals*...............................* 122

Rational number*.................................* 17

Rational number functions _......................._ 47

Rational numerator and denominator*.............* 49

Rational sign tests _..............................._ 49 Raw output internals*............................* 125

Reallocations _...................................._ 23

Reentrancy _......................................_ 21 References _......................................_ 130

Remove factor functions*..........................* 39

Reporting bugs _.................................._ 30 Root extraction algorithm*.......................* 110

Root extraction algorithms*......................* 109

Root extraction functions*.....................* 37, 56

Root testing functions*............................* 37

Rounding functions _.............................._ 58

**S**

Sample programs*.................................* 22 Scan bit functions*................................* 41 scanf formatted input _..........................._ 79 SCO*.............................................* 15

Seeding random numbers*.........................* 73

Segmentation violation*...........................* 25

Sequent Symmetry*...............................* 15

Services for Unix*.................................* 13

Shared library versioning*.........................* 11

Sign tests*.................................* 40, 49, 57

Size in digits*.....................................* 45

Small operands _.................................._ 23

Solaris _......................................._ 10, 15

Sparc _............................................_ 14

Sparc V9*.........................................* 10

Special integer functions _........................._ 45 Square root algorithm*...........................* 110 SSE2 _............................................_ 14

Stack backtrace _.................................._ 26

Stack overflow*.................................* 7, 25 Static linking _...................................._ 23 stdarg.h _........................................_ 17 stdio.h*..........................................* 17 Stripped libraries _................................_ 14

Sun*..............................................* 10

SunOS*...........................................* 14

Systems*..........................................* 12

**T**

Temporary memory _..............................._ 7

Texinfo _..........................................._ 7

Text input/output _..............................._ 25

Thread safety*....................................* 21

Toom multiplication _...................._ 98, 100, 102 Types*............................................* 17

**U**

ui and si functions _.............................._ 23 Unbalanced multiplication*.......................* 102 Upward compatibility _............................_ 22

Useful macros and constants _....................._ 22

User-defined precision*............................* 52

**V**

Valgrind _........................................._ 27

Variable conventions _............................._ 19

Version number _.................................._ 22

**W**

Web page _........................................._ 2

Windows*.........................................* 13

**X**

Function and Type Index

**Function and Type Index**

x86 _.............................................._ 14 x87 _.............................................._ 12 XML*..............................................* 7 \__GMP_CC _........................................\_ 22

\__GMP_CFLAGS_....................................\_22 \__GNU_MP_VERSION _...............................\_ 22

\__GNU_MP_VERSION_MINOR _........................\_ 22

\__GNU_MP_VERSION_PATCHLEVEL_...................\_ 22

\_mpz*realloc*....................................\_ 45

**A**

abs*.......................................* 85, 86, 88

**C**

ceil*.............................................* 88 cmp*.......................................* 85, 86, 88

**F**

factorial _......................................._ 85 fibonacci _......................................._ 85 floor*............................................* 88

**G**

gcd _.............................................._ 85 gmp*asprintf*...................................._77 gmp_errno _......................................._ 73 gmp_fprintf_....................................._76 gmp_fscanf _......................................_ 81 gmp_obstack_printf_............................._ 77 gmp_obstack_vprintf_............................_ 77 gmp_printf _......................................_ 76 gmp_randclass_..................................._ 89 gmp_randclass::get_f_..........................._ 90 gmp_randclass::get_z_bits_....................._90 gmp_randclass::get_z_range_...................._ 90 gmp_randclass::gmp_randclass _................._ 89 gmp_randclass::seed_............................_90 gmp_randclear_..................................._ 73 gmp_randinit_...................................._72 gmp_randinit_default_..........................._72 gmp_randinit_lc_2exp_..........................._ 72 gmp_randinit_lc_2exp_size_....................._ 72 gmp_randinit_mt _................................_ 72 gmp_randinit_set _..............................._ 72 gmp_randseed_...................................._73 gmp_randseed_ui _................................_ 73 gmp_randstate_ptr _.............................._ 18 gmp_randstate_srcptr_..........................._18 gmp_randstate_t _................................_ 18 gmp_scanf _......................................._ 81 gmp_snprintf_...................................._76 gmp_sprintf_....................................._ 76 gmp_sscanf _......................................_ 81 gmp_urandomb_ui _................................_ 73 gmp_urandomm_ui _................................_ 73 gmp_vasprintf_..................................._ 77 gmp_version_....................................._22 gmp_vfprintf_...................................._ 76 gmp_vfscanf_....................................._81 gmp_vprintf_....................................._ 76 gmp_vscanf _......................................_ 81 gmp_vsnprintf_..................................._ 76 gmp_vsprintf_...................................._76 gmp_vsscanf_....................................._ 81 GMP_ERROR_INVALID_ARGUMENT_....................\_ 73

GMP*ERROR_UNSUPPORTED_ARGUMENT *...............\_ 73

GMP*LIMB_BITS*...................................\_ 70

GMP*NAIL_BITS*...................................\_ 70

GMP*NAIL_MASK*...................................\_ 71

GMP*NUMB_BITS*...................................\_ 70

GMP*NUMB_MASK*...................................\_ 71

GMP*NUMB_MAX*....................................\_ 71

GMP*RAND_ALG_DEFAULT*..........................._72 GMP_RAND_ALG_LC _................................\_ 72

**H**

hypot*............................................* 88

**L**

lcm _.............................................._ 85

**M**

| Function and Type Index | |
| --- | |
| |

mp*bitcnt_t*....................................._ 18 mp_bits_per_limb _..............................._ 22 mp_exp_t _........................................_ 18 mp_get_memory_functions _......................._ 93 mp_limb_t _......................................._ 18 mp_set_memory_functions _......................._ 92 mp_size_t _......................................._ 18 mpf_abs_.........................................._ 57 mpf_add_.........................................._56 mpf_add_ui _......................................_ 56 mpf_ceil _........................................_ 58 mpf_class _......................................._ 83 mpf_class::fits_sint_p _........................_ 88 mpf_class::fits_slong_p _......................._ 88 mpf_class::fits_sshort_p_......................_ 88 mpf_class::fits_uint_p _........................_ 88 mpf_class::fits_ulong_p _......................._ 88 mpf_class::fits_ushort_p_......................_88 mpf_class::get_d _..............................._ 88 mpf_class::get_mpf_t_..........................._ 84 mpf_class::get_prec_............................_ 89 mpf_class::get_si _.............................._ 89 mpf_class::get_str_............................._ 89 mpf_class::get_ui _.............................._ 89 mpf_class::mpf_class_......................._ 87, 88 mpf_class::operator=_..........................._ 88 mpf_class::set_prec_............................_89 mpf_class::set_prec_raw _......................._ 89 mpf_class::set_str_............................._ 89 mpf_class::swap _................................_ 89 mpf_clear _......................................._ 53 mpf_clears _......................................_ 53 mpf_cmp_.........................................._ 57 mpf_cmp_d _......................................._ 57 mpf_cmp_si _......................................_ 57 mpf_cmp_ui _......................................_ 57 mpf_cmp_z _......................................._ 57 mpf_div_.........................................._56 mpf_div_2exp_...................................._57 mpf_div_ui _......................................_ 56 mpf_eq_..........................................._ 57 mpf_fits_sint_p _................................_ 58 mpf_fits_slong_p _..............................._ 58 mpf_fits_sshort_p _.............................._ 58 mpf_fits_uint_p _................................_ 58 mpf_fits_ulong_p _..............................._ 58 mpf_fits_ushort_p _.............................._ 58 mpf_floor _......................................._ 58 mpf_get_d _......................................._ 55 mpf_get_d_2exp _................................._ 55 mpf_get_default_prec_..........................._52 mpf_get_prec_...................................._53 mpf_get_si _......................................_ 55 mpf_get_str_....................................._56 mpf_get_ui _......................................_ 55 mpf_init _........................................_ 53 mpf_init_set_...................................._ 55 mpf_init_set_d _................................._ 55 mpf_init_set_si _................................_ 55 mpf_init_set_str _..............................._ 55 mpf_init_set_ui _................................_ 55 mpf_init2 _......................................._ 53 mpf_inits _......................................._ 53 mpf_inp_str_....................................._ 58 mpf_integer_p_..................................._ 58 mpf_mul_.........................................._56 mpf_mul_2exp_...................................._57 mpf_mul_ui _......................................_ 56 mpf_neg_.........................................._ 57 mpf_out_str_....................................._ 58 mpf_pow_ui _......................................_ 57 mpf_ptr_.........................................._18 mpf_random2_....................................._ 59 mpf_reldiff_....................................._57 mpf_set_.........................................._ 54 mpf_set_d _......................................._ 54 mpf_set_default_prec_..........................._52 mpf_set_prec_...................................._53 mpf_set_prec_raw _..............................._ 53 mpf_set_q _......................................._ 54 mpf_set_si _......................................_ 54 mpf_set_str_....................................._ 54 mpf_set_ui _......................................_ 54 mpf_set_z _......................................._ 54 mpf_sgn_.........................................._57 mpf_sqrt _........................................_ 56 mpf_sqrt_ui_....................................._ 56 mpf_srcptr _......................................_ 18 mpf_sub_.........................................._ 56 mpf_sub_ui _......................................_ 56 mpf_swap _........................................_ 54 mpf_t_............................................_ 17 mpf_trunc _......................................._ 58 mpf_ui_div _......................................_ 56 mpf_ui_sub _......................................_ 56 mpf_urandomb_...................................._ 59 mpn_add_.........................................._60 mpn_add_1 _......................................._ 60 mpn_add_n _......................................._ 60 mpn_addmul_1_...................................._62 mpn_and_n _......................................._ 66 mpn_andn_n _......................................_ 67 mpn_cmp_.........................................._ 64 mpn_cnd_add_n_..................................._68 mpn_cnd_sub_n_..................................._ 68 mpn_cnd_swap_...................................._ 68 mpn_com_.........................................._67 mpn_copyd _......................................._ 67 mpn_copyi _......................................._ 67 mpn_divexact_1 _................................._ 63 mpn_divexact_by3 _..............................._ 63 mpn_divexact_by3c _.............................._ 63 mpn_divmod _......................................_ 63 mpn_divmod_1_...................................._ 63 mpn_divrem _......................................_ 62 mpn_divrem_1_...................................._63 mpn_gcd_.........................................._ 64 mpn_gcd_1 _......................................._ 64 mpn_gcdext _......................................_ 64 mpn_get_str_....................................._65 mpn_hamdist_....................................._ 66 mpn_ior_n _......................................._ 66 mpn_iorn_n _......................................_ 67 mpn_lshift _......................................_ 64 mpn_mod_1 _......................................._ 63 mpn_mul_.........................................._ 61 mpn_mul_1 _......................................._ 62 mpn_mul_n _......................................._ 61 mpn_nand_n _......................................_ 67 mpn_neg_.........................................._61 mpn_nior_n _......................................_ 67 mpn_perfect_square_p_..........................._ 66 mpn_popcount_...................................._66 mpn_random _......................................_ 66 mpn_random2_....................................._66 mpn_rshift _......................................_ 64 mpn_scan0 _......................................._ 66 mpn_scan1 _......................................._ 66 mpn_sec_add_1_..................................._68 mpn_sec_div_qr _................................._ 69 mpn_sec_div_qr_itch_............................_ 69 mpn_sec_div_r_..................................._69 mpn_sec_div_r_itch_............................._69 mpn_sec_invert _................................._ 70 mpn_sec_invert_itch_............................_ 70 mpn_sec_mul_....................................._ 68 mpn_sec_mul_itch _..............................._ 68 mpn_sec_powm_...................................._69 mpn_sec_powm_itch _.............................._ 69 mpn_sec_sqr_....................................._ 69 mpn_sec_sqr_itch _..............................._ 69 mpn_sec_sub_1_..................................._ 68 mpn_sec_tabselect _.............................._ 69 mpn_set_str_....................................._ 65 mpn_sizeinbase _................................._ 65 mpn_sqr_.........................................._ 61 mpn_sqrtrem_....................................._65 mpn_sub_.........................................._ 61 mpn_sub_1 _......................................._ 61 mpn_sub_n _......................................._ 61 mpn_submul_1_...................................._ 62 mpn_tdiv_qr_....................................._ 62 mpn_xnor_n _......................................_ 67 mpn_xor_n _......................................._ 66 mpn_zero _........................................_ 67 mpn_zero_p _......................................_ 64 mpq_abs_.........................................._ 49 mpq_add_.........................................._48 mpq_canonicalize _..............................._ 47 mpq_class _......................................._ 83 mpq_class::canonicalize _......................._ 86 mpq_class::get_d _..............................._ 86 mpq_class::get_den_............................._ 87 mpq_class::get_den_mpz_t_......................_ 87 mpq_class::get_mpq_t_..........................._84 mpq_class::get_num_............................._87 mpq_class::get_num_mpz_t_......................_87 mpq_class::get_str_............................._86 mpq_class::mpq_class_..........................._86 mpq_class::set_str_............................._86 mpq_class::swap _................................_ 86 mpq_clear _......................................._ 47 mpq_clears _......................................_ 47 mpq_cmp_.........................................._49 mpq_cmp_si _......................................_ 49 mpq_cmp_ui _......................................_ 49 mpq_cmp_z _......................................._ 49 mpq_denref _......................................_ 50 mpq_div_.........................................._49 mpq_div_2exp_...................................._49 mpq_equal _......................................._ 49 mpq_get_d _......................................._ 48 mpq_get_den_....................................._ 50 mpq_get_num_....................................._ 50 mpq_get_str_....................................._ 48 mpq_init _........................................_ 47 mpq_inits _......................................._ 47 mpq_inp_str_....................................._ 50 mpq_inv_.........................................._49 mpq_mul_.........................................._ 48 mpq_mul_2exp_...................................._ 49 mpq_neg_.........................................._49 mpq_numref _......................................_ 50 mpq_out_str_....................................._ 50 mpq_ptr_.........................................._18 mpq_set_.........................................._ 47 mpq_set_d _......................................._ 48 mpq_set_den_....................................._ 50 mpq_set_f _......................................._ 48 mpq_set_num_....................................._ 50 mpq_set_si _......................................_ 47 mpq_set_str_....................................._ 47 mpq_set_ui _......................................_ 47 mpq_set_z _......................................._ 47 mpq_sgn_.........................................._49 mpq_srcptr _......................................_ 18 mpq_sub_.........................................._48 mpq_swap _........................................_ 48 mpq_t_............................................_17 mpz_2fac_ui_....................................._39 mpz_abs_.........................................._ 34 mpz_add_.........................................._34 mpz_add_ui _......................................_ 34 mpz_addmul _......................................_ 34 mpz_addmul_ui_..................................._ 34 mpz_and_.........................................._40 mpz_array_init _................................._ 45 mpz_bin_ui _......................................_ 39 mpz_bin_uiui_...................................._39 mpz_cdiv_q _......................................_ 34 mpz_cdiv_q_2exp _................................_ 35 mpz_cdiv_q_ui_..................................._34 mpz_cdiv_qr_....................................._34 mpz_cdiv_qr_ui _................................._ 35 mpz_cdiv_r _......................................_ 34 mpz_cdiv_r_2exp _................................_ 35 mpz_cdiv_r_ui_..................................._ 35 mpz_cdiv_ui_....................................._ 35 mpz_class _......................................._ 83 mpz_class::factorial_..........................._ 85 mpz_class::fibonacci_..........................._85 mpz_class::fits_sint_p _........................_ 85 mpz_class::fits_slong_p _......................._ 85 mpz_class::fits_sshort_p_......................_ 85 mpz_class::fits_uint_p _........................_ 85 mpz_class::fits_ulong_p _......................._ 85 mpz_class::fits_ushort_p_......................_85 mpz_class::get_d _..............................._ 85 mpz_class::get_mpz_t_..........................._ 84 mpz_class::get_si _.............................._ 85 mpz_class::get_str_............................._ 85 mpz_class::get_ui _.............................._ 85 mpz_class::mpz_class_..........................._ 84 mpz_class::primorial_..........................._85 mpz_class::set_str_............................._85 mpz_class::swap _................................_ 85 mpz_clear _......................................._ 31 mpz_clears _......................................_ 31 mpz_clrbit _......................................_ 41 mpz_cmp_.........................................._ 40 mpz_cmp_d _......................................._ 40 mpz_cmp_si _......................................_ 40 mpz_cmp_ui _......................................_ 40 mpz_cmpabs _......................................_ 40 mpz_cmpabs_d_...................................._40 mpz_cmpabs_ui_..................................._40 mpz_com_.........................................._ 41 mpz_combit _......................................_ 41 mpz_congruent_2exp_p_..........................._ 36 mpz_congruent_p _................................_ 36 mpz_congruent_ui_p_............................._36 mpz_divexact_...................................._ 36 mpz_divexact_ui _................................_ 36 mpz_divisible_2exp_p_..........................._36 mpz_divisible_p _................................_ 36 mpz_divisible_ui_p_............................._ 36 mpz_even_p _......................................_ 45 mpz_export _......................................_ 44 mpz_fac_ui _......................................_ 39 mpz_fdiv_q _......................................_ 35 mpz_fdiv_q_2exp _................................_ 35 mpz_fdiv_q_ui_..................................._35 mpz_fdiv_qr_....................................._35 mpz_fdiv_qr_ui _................................._ 35 mpz_fdiv_r _......................................_ 35 mpz_fdiv_r_2exp _................................_ 35 mpz_fdiv_r_ui_..................................._ 35 mpz_fdiv_ui_....................................._ 35 mpz_fib_ui _......................................_ 40 mpz_fib2_ui_....................................._ 40 mpz_fits_sint_p _................................_ 44 mpz_fits_slong_p _..............................._ 44 mpz_fits_sshort_p _.............................._ 44 mpz_fits_uint_p _................................_ 44 mpz_fits_ulong_p _..............................._ 44 mpz_fits_ushort_p _.............................._ 44 mpz_gcd_.........................................._38 mpz_gcd_ui _......................................_ 38 mpz_gcdext _......................................_ 38 mpz_get_d _......................................._ 33 mpz_get_d_2exp _................................._ 33 mpz_get_si _......................................_ 33 mpz_get_str_....................................._33 mpz_get_ui _......................................_ 33 mpz_getlimbn_...................................._ 45 mpz_hamdist_....................................._41 mpz_import _......................................_ 43 mpz_init _........................................_ 31 mpz_init_set_...................................._33 mpz_init_set_d _................................._ 33 mpz_init_set_si _................................_ 33 mpz_init_set_str _..............................._ 33 mpz_init_set_ui _................................_ 33 mpz_init2 _......................................._ 31 mpz_inits _......................................._ 31 mpz_inp_raw_....................................._42 mpz_inp_str_....................................._42 mpz_invert _......................................_ 39 mpz_ior_.........................................._41 mpz_jacobi _......................................_ 39 mpz_kronecker_..................................._39 mpz_kronecker_si _..............................._ 39 mpz_kronecker_ui _..............................._ 39 mpz_lcm_.........................................._ 39 mpz_lcm_ui _......................................_ 39 mpz_legendre_...................................._39 mpz_limbs_finish _..............................._ 46 mpz_limbs_modify _..............................._ 45 mpz_limbs_read _................................._ 45 mpz_limbs_write _................................_ 45 mpz_lucnum_ui_..................................._40 mpz_lucnum2_ui _................................._ 40 mpz_mfac_uiui_..................................._39 mpz_mod_.........................................._ 36 mpz_mod_ui _......................................_ 36 mpz_mul_.........................................._34 mpz_mul_2exp_...................................._34 mpz_mul_si _......................................_ 34 mpz_mul_ui _......................................_ 34 mpz_neg_.........................................._ 34 mpz_nextprime_..................................._38 mpz_odd_p _......................................._ 45 mpz_out_raw_....................................._42 mpz_out_str_....................................._42 mpz_perfect_power_p_............................_ 37 mpz_perfect_square_p_..........................._37 mpz_popcount_...................................._ 41 mpz_pow_ui _......................................_ 37 mpz_powm _........................................_ 36 mpz_powm_sec_...................................._37 mpz_powm_ui_....................................._36 mpz_prevprime_..................................._ 38 mpz_primorial_ui _..............................._ 39 mpz_probab_prime_p_............................._38 mpz_ptr_.........................................._ 18 mpz_random _......................................_ 43 mpz_random2_....................................._ 43 mpz_realloc2_...................................._31 mpz_remove _......................................_ 39 mpz_roinit_n_...................................._ 46 mpz_root _........................................_ 37 mpz_rootrem_....................................._ 37 mpz_rrandomb_...................................._43 mpz_scan0 _......................................._ 41 mpz_scan1 _......................................._ 41 mpz_set_.........................................._ 32 mpz_set_d _......................................._ 32 mpz_set_f _......................................._ 32 mpz_set_q _......................................._ 32 mpz_set_si _......................................_ 32 mpz_set_str_....................................._ 32 mpz_set_ui _......................................_ 32 mpz_setbit _......................................_ 41 mpz_sgn_.........................................._ 40 mpz_si_kronecker _..............................._ 39 mpz_size _........................................_ 45 mpz_sizeinbase _................................._ 45 mpz_sqrt _........................................_ 37 mpz_sqrtrem_....................................._ 37 mpz_srcptr _......................................_ 18 mpz_sub_.........................................._ 34 mpz_sub_ui _......................................_ 34 mpz_submul _......................................_ 34 mpz_submul_ui_..................................._34 mpz_swap _........................................_ 32 mpz_t_............................................_17 mpz_tdiv_q _......................................_ 35 mpz_tdiv_q_2exp _................................_ 35 mpz_tdiv_q_ui_..................................._35 mpz_tdiv_qr_....................................._35 mpz_tdiv_qr_ui _................................._ 35 mpz_tdiv_r _......................................_ 35 mpz_tdiv_r_2exp _................................_ 35 mpz_tdiv_r_ui_..................................._ 35 mpz_tdiv_ui_....................................._ 35 mpz_tstbit _......................................_ 41 mpz_ui_kronecker _..............................._ 39 mpz_ui_pow_ui_..................................._ 37 mpz_ui_sub _......................................_ 34 mpz_urandomb_...................................._42 mpz_urandomm_...................................._ 43 mpz_xor_.........................................._41 MPZ_ROINIT_N_....................................\_ 46

**O**

operator""_..............................._ 85, 86, 88 operator% _......................................._ 85 operator/ _......................................._ 85 operator<< _......................................_ 77 operator>>_..............................._ 81, 82, 87

**P**

primorial _......................................._ 85

**S**

sgn*.......................................* 85, 86, 89 sqrt _........................................._ 85, 89 swap*......................................* 85, 86, 89

**T**

trunc*............................................* 89