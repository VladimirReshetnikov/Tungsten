% Compare matrix-vector product accuracy in floating-point and
% level-index arithmetics.
%
% References
%
% M. Mikaitis, MATLAB Simulator of Level Index Arithmetic,
% arXiv:2402.02301 [cs.MS]. Feb. 2024.

clear all;

nlist = round(logspace(1,4,20));

% Set up cpfloat options
options.format = 'fp16';
options.round = 1;
options.explim = 1;
cpfloat([], options);
k = 0;

for n = nlist
    k = k + 1;
    fprintf('k = %2d, n = %7d\n',k,n);
    A = rand(10,n)*100;
    x = rand(n,1);

    % Set up SLI vectors
    Asli = zeros(10, n, 2, 12, 'sli');
    xsli = zeros(n, 1, 2, 12, 'sli');

    % Convert vectors to SLI
    for j = 1:numel(A)
       Asli(j) = Asli(j).set_val(A(j));
    end
    for j = 1:numel(x)
       xsli(j) = xsli(j).set_val(x(j));
    end

    % Double reference result
    ye = A*x;
    absAx = abs(A)*abs(x);

    % Binary16 result
    y1 = mtimesv(A,x,options);
    berr1(k) = max(abs(ye-y1)./absAx);

    % Level index 2.12
    y2 = Asli*xsli;
    berr2(k) = max(abs(ye-[y2.value]')./absAx);
end

filename = sprintf('matvec_binary16_1.dat');
fid = fopen(filename, 'w');
for i=1:length(nlist)
    fprintf(fid, "%d %f %f\n", nlist(i), berr1(i), berr2(i));
end
fclose(fid);

loglog(nlist, berr1, '-*', ...
      nlist, berr2, '-o');
legend('binary16', 'level index 2.12');

function y = mtimesv(A,x,options)
    [m,n] = size(A);
    y = zeros(m,1);
    for i=1:n
        y = cpfloat(y + cpfloat(A(:,i)*x(i), options), options);
    end
end
