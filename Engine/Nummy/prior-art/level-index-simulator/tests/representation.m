clear all;

n = 1000;
step = 10^-5;
upper = n/2 * step;
lower = -upper;

% Set up cpfloat options
options.format = 'b';
options.round = 1;
options.explim = 1;
cpfloat([], options);
k = 0;

number = lower;

for i = 1:n

    numbers(i) = number;

    yfp16 = cpfloat(number, options);

    ysli = sli(2, 12);
    ysli = ysli.set_val(number);

    if (number ~= 0)
        err1(i) = abs((number - yfp16)/number);
        err2(i) = abs((number - ysli.value)/number);
    end

    number = number + step;
end

filename = sprintf('representation_bfloat16.dat');
fid = fopen(filename, 'w');
for i=1:n
    fprintf(fid, "%d %f %f\n", numbers(i), err1(i), err2(i));
end
fclose(fid);

semilogy(numbers, err2, '-*', ...
      numbers, err1, '-o');
legend('level index 2.12', 'binary16');