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
    multiplicand = rand(1);
    multiplicands(i) = multiplicand;
    multiplicandfp16 = cpfloat(multiplicand, options);
    multiplicandsli = sli(2, 12);
    multiplicandsli = multiplicandsli.set_val(multiplicand);

    yfp16 = cpfloat(number, options);
    yfp16 = cpfloat(yfp16*multiplicand, options);

    ysli = sli(2, 12);
    ysli = ysli.set_val(number);
    ysli = ysli * multiplicandsli;

    if (number*multiplicand ~= 0)
        err1(i) = abs((number*multiplicand - yfp16)/...
            (number*multiplicand));
        err2(i) = abs((number*multiplicand - ysli.value)/...
            (number*multiplicand));
    end

    number = number + step;
end

semilogy(numbers, err2, '-*', ...
      numbers, err1, '-o');
legend('level index 2.12', 'binary16');