% Tests for various symmetric level-index arithmetic operations on sli.m
% objects.

% Addition

x = sli(2, 12);
y = sli(2, 12);

x = x.set_val(1);
y = y.set_val(0.2);
z = x+y;
z = z(1);
assert(round(10*z.value)/10 == 1.2)

x = x.set_val(1);
y = y.set_val(0.2);
z = y+x;
z = z(1);
assert(round(10*z.value)/10 == 1.2)

x = x.set_val(1);
y = y.set_val(-0.2);
z = x+y;
z = z(1);
assert(round(10*z.value)/10 == 0.8)

x = x.set_val(1);
y = y.set_val(-0.2);
z = y+x;
z = z(1);
assert(round(10*z.value)/10 == 0.8)

x = x.set_val(-1);
y = y.set_val(0.2);
z = x+y;
z = z(1);
assert(round(10*z.value)/10 == -0.8)

x = x.set_val(-1);
y = y.set_val(0.2);
z = y+x;
z = z(1);
assert(round(10*z.value)/10 == -0.8)

x = x.set_val(-1);
y = y.set_val(-0.2);
z = x+y;
z = z(1);
assert(round(10*z.value)/10 == -1.2)

x = x.set_val(-1);
y = y.set_val(-0.2);
z = y+x;
z = z(1);
assert(round(10*z.value)/10 == -1.2)

% Subtraction

x = x.set_val(1);
y = y.set_val(0.2);
z = x-y;
z = z(1);
assert(round(10*z.value)/10 == 0.8)

x = x.set_val(1);
y = y.set_val(0.2);
z = y-x;
z = z(1);
assert(round(10*z.value)/10 == -0.8)

x = x.set_val(1);
y = y.set_val(-0.2);
z = x-y;
z = z(1);
assert(round(10*z.value)/10 == 1.2)

x = x.set_val(1);
y = y.set_val(-0.2);
z = y-x;
z = z(1);
assert(round(10*z.value)/10 == -1.2)

x = x.set_val(-1);
y = y.set_val(0.2);
z = x-y;
z = z(1);
assert(round(10*z.value)/10 == -1.2)

x = x.set_val(-1);
y = y.set_val(0.2);
z = y-x;
z = z(1);
assert(round(10*z.value)/10 == 1.2)

x = x.set_val(-1);
y = y.set_val(-0.2);
z = x-y;
z = z(1);
assert(round(10*z.value)/10 == -0.8)

x = x.set_val(-1);
y = y.set_val(-0.2);
z = y-x;
z = z(1);
assert(round(10*z.value)/10 == 0.8)

% Multiplication

x = x.set_val(2);
y = y.set_val(2.5);
z = x.*y;
z = z(1);
assert(round(z.value) == 5)
z = y.*x;
z = z(1);
assert(round(z.value) == 5)

y = y.set_val(-2.5);
z = x.*y;
z = z(1);
assert(floor(z.value) == -5)
z = y.*x;
z = z(1);
assert(floor(z.value) == -5)

x = x.set_val(-2);
z = x.*y;
z = z(1);
assert(ceil(z.value) == 5)
z = y.*x;
z = z(1);
assert(ceil(z.value) == 5)

x = x.set_val(2);
y = y.set_val(10);
z = x.*y;
z = z(1);
assert(round(z.value) == 20)
z = y.*x;
z = z(1);
assert(round(z.value) == 20)

y = y.set_val(1);
z = x.*y;
z = z(1);
assert(ceil(z.value) == 2)
z = y.*x;
z = z(1);
assert(ceil(z.value) == 2)

y = y.set_val(0.5);
z = x.*y;
z = z(1);
assert(round(z.value) == 1)
z = y.*x;
z = z(1);
assert(round(z.value) == 1)

x = x.set_val(0.8);
y = y.set_val(0.5);
y.value;
z = x.*y;
z = z(1);
assert(round(z.value*10)/10 == 0.4)
z = y.*x;
z = z(1);
assert(round(z.value*10)/10 == 0.4)

% Division

x = x.set_val(300);
y = y.set_val(150);
z = x./y;
z = z(1);
assert(round(z.value) == 2)
z = y./x;
z = z(1);
assert(round(10*z.value)/10 == 0.5)

y = y.set_val(-150);
z = x./y;
z = z(1);
assert(round(z.value) == -2)
z = y./x;
z = z(1);
assert(round(10*z.value)/10 == -0.5)

x = x.set_val(-300);
z = x./y;
z = z(1);
assert(round(z.value) == 2)
z = y./x;
z = z(1);
assert(round(10*z.value)/10 == 0.5)

x = x.set_val(300);
y = y.set_val(10);
z = x./y;
z = z(1);
assert(round(z.value) == 30)
z = y./x;
z = z(1);
assert(floor(1000*z.value)/1000 == 0.033)

y = y.set_val(1);
z = x./y;
z = z(1);
assert(round(z.value) == 300)
z = y./x;
z = z(1);
assert(floor(1000*z.value)/1000 == 0.003)

x = x.set_val(2);
y = y.set_val(0.5);
z = x./y;
z = z(1);
assert(round(z.value) == 4)
z = y./x;
z = z(1);
assert(round(z.value*100)/100 == 0.25)

x = x.set_val(0.8);
y = y.set_val(0.5);
z = x./y;
z = z(1);
assert(round(10*z.value)/10 == 1.6)
z = y./x;
z = z(1);
assert(round(1000*z.value)/1000 == 0.625)

% Special cases

x = x.set_val(0);
y = y.set_val(2);
z = x.*y;
z = z(1);
assert(z.value == 0);
z = y.*z;
z = z(1);
assert(z.value == 0);
z = x+y;
z = z(1);
assert(round(z.value) == 2);
z = y+x;
z = z(1);
assert(round(z.value) == 2);
z = x-y;
z = z(1);
assert(round(z.value) == -2);
z = y-x;
z = z(1);
assert(round(z.value) == 2);
z = x./y;
z = z(1);
assert(z.value == 0);
zero_div_err = 0;
try z = y./x;
catch
    zero_div_err = 1;
end
assert(zero_div_err == 1);

% Vectors and matrices

% A = [1 2 3] A' = [1 4]
%     [4 5 6]      [2 5]
%                  [3 6]
%
A = sli.zeros(2, 3, 2, 12);
A(1,1) = A(1,1).set_val(1);
A(1,2) = A(1,2).set_val(2);
A(1,3) = A(1,3).set_val(3);
A(2,1) = A(2,1).set_val(4);
A(2,2) = A(2,2).set_val(5);
A(2,3) = A(2,3).set_val(6);

Y = A*A.';
assert(round(Y(1,1).value) == 14)
assert(round(Y(1,2).value) == 32)
assert(round(Y(2,1).value) == 32)
assert(round(Y(2,2).value) == 77)

% b = [1 2 3]
b = sli.zeros(3, 2, 12);
b(:) = A(1, :);
Y = A*b.';
assert(round(Y(1,1).value) == 14)
assert(round(Y(2,1).value) == 32)

Y = A+A;
assert(round(Y(1,1).value) == 2)
assert(round(Y(1,2).value) == 4)
assert(round(Y(1,3).value) == 6)
assert(round(Y(2,1).value) == 8)
assert(round(Y(2,2).value) == 10)
assert(round(Y(2,3).value) == 12)

Y = A-A;
assert(round(Y(1,1).value) == 0)
assert(round(Y(1,2).value) == 0)
assert(round(Y(1,3).value) == 0)
assert(round(Y(2,1).value) == 0)
assert(round(Y(2,2).value) == 0)
assert(round(Y(2,3).value) == 0)

Y = A.*A;
assert(round(Y(1,1).value) == 1)
assert(round(Y(1,2).value) == 4)
assert(round(Y(1,3).value) == 9)
assert(round(Y(2,1).value) == 16)
assert(round(Y(2,2).value) == 25)
assert(round(Y(2,3).value) == 36)

Y = A./A;
assert(round(Y(1,1).value) == 1)
assert(round(Y(1,2).value) == 1)
assert(round(Y(1,3).value) == 1)
assert(round(Y(2,1).value) == 1)
assert(round(Y(2,2).value) == 1)
assert(round(Y(2,3).value) == 1)

Y = A.\A;
assert(round(Y(1,1).value) == 1)
assert(round(Y(1,2).value) == 1)
assert(round(Y(1,3).value) == 1)
assert(round(Y(2,1).value) == 1)
assert(round(Y(2,2).value) == 1)
assert(round(Y(2,3).value) == 1)

x = x.set_val(1);
Y = A+x;
assert(round(Y(1,1).value) == 2)
assert(round(Y(1,2).value) == 3)
assert(round(Y(1,3).value) == 4)
assert(round(Y(2,1).value) == 5)
assert(round(Y(2,2).value) == 6)
assert(round(Y(2,3).value) == 7)
Y = x+A;
assert(round(Y(1,1).value) == 2)
assert(round(Y(1,2).value) == 3)
assert(round(Y(1,3).value) == 4)
assert(round(Y(2,1).value) == 5)
assert(round(Y(2,2).value) == 6)
assert(round(Y(2,3).value) == 7)

 Y = A-x;
assert(round(Y(1,1).value) == 0)
assert(round(Y(1,2).value) == 1)
assert(round(Y(1,3).value) == 2)
assert(round(Y(2,1).value) == 3)
assert(round(Y(2,2).value) == 4)
assert(round(Y(2,3).value) == 5)
Y = x-A;
assert(round(Y(1,1).value) == 0)
assert(round(Y(1,2).value) == -1)
assert(round(Y(1,3).value) == -2)
assert(round(Y(2,1).value) == -3)
assert(round(Y(2,2).value) == -4)
assert(round(Y(2,3).value) == -5)

x = x.set_val(2);
Y = A.*x;
assert(round(Y(1,1).value) == 2)
assert(round(Y(1,2).value) == 4)
assert(round(Y(1,3).value) == 6)
assert(round(Y(2,1).value) == 8)
assert(round(Y(2,2).value) == 10)
assert(round(Y(2,3).value) == 12)
Y = x.*A;
assert(round(Y(1,1).value) == 2)
assert(round(Y(1,2).value) == 4)
assert(round(Y(1,3).value) == 6)
assert(round(Y(2,1).value) == 8)
assert(round(Y(2,2).value) == 10)
assert(round(Y(2,3).value) == 12)

Y = A./x;
assert(round(10*Y(1,1).value)/10 == 0.5)
assert(round(Y(1,2).value) == 1)
assert(round(10*Y(1,3).value)/10 == 1.5)
assert(round(Y(2,1).value) == 2)
assert(round(10*Y(2,2).value)/10 == 2.5)
assert(round(Y(2,3).value) == 3)
Y = x./A;
assert(round(Y(1,1).value) == 2)
assert(round(Y(1,2).value) == 1)
assert(round(10*Y(1,3).value)/10 == 0.7)
assert(round(10*Y(2,1).value)/10 == 0.5)
assert(round(10*Y(2,2).value)/10 == 0.4)
assert(round(10*Y(2,3).value)/10 == 0.3)

% A = [1 2 3] x = [1]
%     [4 5 6]     [2]
%
%
x = sli.zeros(2, 1, 2, 12);
x(1,1) = x(1,1).set_val(1);
x(2,1) = x(2,1).set_val(2);
Y = A+x;
assert(round(Y(1,1).value) == 2)
assert(round(Y(1,2).value) == 3)
assert(round(Y(1,3).value) == 4)
assert(round(Y(2,1).value) == 6)
assert(round(Y(2,2).value) == 7)
assert(round(Y(2,3).value) == 8)

% A = [1 2 3] x = [1]
%                 [2]
%
A = A(1, :);
Y = A+x;
assert(round(Y(1,1).value) == 2)
assert(round(Y(1,2).value) == 3)
assert(round(Y(1,3).value) == 4)
assert(round(Y(2,1).value) == 3)
assert(round(Y(2,2).value) == 4)
assert(round(Y(2,3).value) == 5)

% A = [1] x = [1, 2]
%     [2]
%     [3]
Y = A'+x';
assert(round(Y(1,1).value) == 2)
assert(round(Y(1,2).value) == 3)
assert(round(Y(2,1).value) == 3)
assert(round(Y(2,2).value) == 4)
assert(round(Y(3,1).value) == 4)
assert(round(Y(3,2).value) == 5)
