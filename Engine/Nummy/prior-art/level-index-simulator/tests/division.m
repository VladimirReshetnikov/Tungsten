clear all;

n = 10000;
step = 10^-3;
upper = n/2 * step;
lower = -upper;

% Set up cpfloat options
options.format = 'fp16';
options.round = 1;
options.explim = 1;
cpfloat([], options);
k = 0;

number = lower;

for i = 1:n

    numbers(i) = number;
    divisor = rand(1)*10;
    divisors(i) = divisor;
    divisorfp16 = cpfloat(divisor, options);
    divisorsli = sli(2, 12);
    divisorsli = divisorsli.set_val(divisor);

    yfp16 = cpfloat(number, options);
    yfp16 = cpfloat(yfp16/divisor, options);

    ysli = sli(2, 12);
    ysli = ysli.set_val(number);
    ysli = ysli./divisorsli;

    if (number/divisor ~= 0)
        err1(i) = abs((number/divisor - yfp16)/(number/divisor));
        err2(i) = abs((number/divisor - ysli.value)/(number/divisor));
    end

    number = number + step;
end

semilogy(numbers, err2, '-*', ...
      numbers, err1, '-o');
legend('level index 2.12', 'binary16');