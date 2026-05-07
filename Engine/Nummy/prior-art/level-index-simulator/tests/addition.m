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
    addend = rand(1);
    addendfp16 = cpfloat(addend, options);
    addendsli = sli(2, 12);
    addendsli = addendsli.set_val(addend);

    yfp16 = cpfloat(number, options);
    yfp16 = cpfloat(yfp16+addend, options);

    ysli = sli(2, 12);
    ysli = ysli.set_val(number);
    ysli = ysli + addendsli;

    if (number+addend ~= 0)
        err1(i) = abs((number+addend - yfp16)/(number+addend));
        err2(i) = abs((number+addend - ysli.value)/(number+addend));
    end

    number = number + step;
end

semilogy(numbers, err2, '-*', ...
      numbers, err1, '-o');
legend('level index 2.12', 'binary16');