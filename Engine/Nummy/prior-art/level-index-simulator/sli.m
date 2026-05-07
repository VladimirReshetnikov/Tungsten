%SLI Symmetric level-index object.
%
% SLI object defines a custom precision symmetric level index number and
% various operations on it.
%
% References
%
% C. W. Clenshaw and F. W. J. Olver, Beyond floating point,
% Journal of the ACM, 31 (1984), p. 319–328.
%
% M. Mikaitis, MATLAB Simulator of Level Index Arithmetic,
% arXiv:2402.02301 [cs.MS]. Feb. 2024. Accepted for ARITH 2024.

classdef sli

    properties
        level_bits = 2
        index_bits = 12
        sign
        reciprocal
        level
        index
        value
    end

    methods
        function obj = sli(lbits, ibits)
            if nargin > 0
                obj.level_bits = lbits;
                obj.index_bits = ibits;
            end
        end

        function obj = set_val(obj, val)
            obj.sign = val < 0;
            temp = abs(val);
            if (temp == 0)
                obj.level = 1;
                obj.index = 0;
                obj.reciprocal = 0;
                obj = update_double(obj);
                obj = obj(1);
                return;
            end
            if (temp < 1)
                temp = 1/temp;
                obj.reciprocal = 0;
            else
                obj.reciprocal = 1;
            end
            obj.level = 0;
            obj.index = temp;
            while (obj.index >= 1)
                obj.level = obj.level + 1;
                obj.index = log(obj.index);
                obj = update_double(obj);
            end
            obj = obj(1);
        end

        function obj = set_sli(obj, s, r, level, index)
            obj.sign = s;
            obj.reciprocal = r;
            if (level == 0)
                error('Zero level is not supported.');
            end
            if level <= 2^obj.level_bits
                obj.level = level;
            else
                obj.level = 2^obj.level_bits;
                warning('Specified level is too big.');
            end
            if (index < 1)
                obj.index = floor(2^obj.index_bits * ...
                    index)/2^(obj.index_bits);
            end
            obj = update_double(obj);
        end

        function r = iszero(obj)
            indices = find([obj.reciprocal] == 0 & ...
                [obj.index] == 0 & [obj.level] == 1);
            if ~isempty(indices)
                r(indices) = deal(1);
            else
                r(1:numel(obj)) = deal(0);
            end
        end

        function r = abs(a)
            [a.sign] = deal(0);
            r = update_double(a);
        end

        function r = nextafter(obj)
            obj.index = obj.index + 2^-obj.index_bits;
            if obj.index == 1
                obj.index = 0;
                obj.level = obj.level + 1;
            end
            r = update_double(obj);
        end

        function r = plus(a, b)
            [a, b] = check_compatible_sizes(a,b);
            r = a;
            for (k = 1:numel(a))
                if iszero(a(k))
                    r(k) = b(k); return;
                elseif iszero(b(k))
                    r(k) = a(k); return;
                end
                if (abs(a(k)) < abs(b(k)))
                    temp = a(k);
                    a(k) = b(k);
                    b(k) = temp;
                end
                if (a(k).sign ~= b(k).sign)
                    r(k) = minus(abs(a(k)),abs(b(k)));
                    r(k) = setfield(r(k), 'sign', a(k).sign);
                    r(k) = update_double(r(k));
                    continue;
                end
                r(k) = main_sli_algorithm(a(k), b(k), 'add');
            end
        end

        function r = minus(a, b)
            [a, b] = check_compatible_sizes(a,b);
            r = a;
            for (k = 1:numel(a))
                if (a(k) == b(k))
                    r(k) = a(k).set_val(0);
                    continue;
                end
                if iszero(a(k))
                    r(k) = b(k);
                    r(k) = setfield(r(k), 'sign', ~b(k).sign);
                    r(k) = update_double(r(k));
                    continue;
                elseif iszero(b(k))
                    r(k) = a(k);
                    continue;
                end
                if (a(k).sign ~= b(k).sign)
                    r(k) = plus(abs(a(k)),abs(b(k)));
                    r(k) = setfield(r(k), 'sign', a(k).sign);
                    r(k) = update_double(r(k));
                    continue;
                end
                if (abs(a(k)) < abs(b(k)))
                    temp = a(k);
                    a(k) = b(k);
                    b(k) = temp;
                    a(k) = setfield(a(k), 'sign', ~a(k).sign);
                end
                r(k) = main_sli_algorithm(a(k), b(k), 'sub');
            end
        end

        function r = uminus(a)
            a.sign = ~a.sign;
            r = a;
            r = update_double(r);
        end

        function r = uplus(a)
            r = a;
            r = update_double(r);
        end

        function r = times(a, b)
            [a, b] = check_compatible_sizes(a,b);
            r = a;
            for (k = 1:numel(a))
                if iszero(a(k))
                    r(k) = a(k);
                    continue;
                elseif iszero(b(k))
                    r(k) = b(k);
                    continue;
                end

                absa = abs(a(k)); absa = absa(1);
                absb = abs(b(k)); absb = absb(1);
                if (li_le(absa, absb))
                    temp = a(k);
                    a(k) = b(k);
                    b(k) = temp;
                end
                a(k) = setfield(a(k), 'level', a(k).level-1);
                b(k) = setfield(b(k), 'level', b(k).level-1);
                absa = abs(a(k)); absa = absa(1);
                absb = abs(b(k)); absb = absb(1);
                if (a(k).reciprocal == b(k).reciprocal)
                    r(k) = li_add(absa, absb);
                else
                    r(k) = li_sub(absa, absb);
                end
                r(k) = setfield(r(k), 'reciprocal', a(k).reciprocal);
                r(k) = setfield(r(k), 'level', r(k).level + 1);
                if (a(k).sign ~= b(k).sign)
                    r(k) = setfield(r(k), 'sign', 1);
                else
                    r(k) = setfield(r(k), 'sign', 0);
                    end
                if (iszero(r(k)))
                    r(k) = setfield(r(k), 'reciprocal', 1);
                end
                r(k) = update_double(r(k));
            end
        end

        function R = mtimes(A, B)
            lbits = A(1).level_bits;
            ibits = A(1).index_bits;
            [m, k1] = size(A);
            [k2, n] = size(B);
            R = sli.zeros(m, n, lbits, ibits);

            if (k1 ~= k2)
                error('Incompatible matrix or vector dimensions.');
            end

            for i = 1:m
                for j = 1:n
                    for k = 1:k1
                        R(i,j) = R(i,j) + A(i, k).*B(k, j);
                    end
                end
            end
        end

        function r = rdivide(a, b)
            [a, b] = check_compatible_sizes(a,b);
            r = a;
            for (k = 1:numel(a))
                if iszero(a(k))
                    r = a(k); continue;
                elseif iszero(b(k))
                    error('Division by zero');
                end
                invert_recipr = 0;
                absa = abs(a(k)); absa = absa(1);
                absb = abs(b(k)); absb = absb(1);
                if (li_le(absa, absb))
                    temp = a(k);
                    a(k) = b(k);
                    b(k) = temp;
                    invert_recipr = 1;
                end
                a(k) = setfield(a(k), 'level', a(k).level-1);
                b(k) = setfield(b(k), 'level', b(k).level-1);
                absa = abs(a(k)); absa = absa(1);
                absb = abs(b(k)); absb = absb(1);
                if (a(k).reciprocal == b(k).reciprocal)
                    r(k) = li_sub(absa, absb);
                else
                    r(k) = li_add(absa, absb);
                end
                r(k) = setfield(r(k), 'reciprocal', a(k).reciprocal);
                r(k) = setfield(r(k), 'level', r(k).level + 1);
                if invert_recipr
                    r(k) = setfield(r(k), 'reciprocal', ~r(k).reciprocal);
                end
                if (a(k).sign ~= b(k).sign)
                    r(k) = setfield(r(k), 'sign', 1);
                else
                    r(k) = setfield(r(k), 'sign', 0);
                end
                if (iszero(r(k)))
                    r(k) = setfield(r(k), 'reciprocal', 1);
                end
                r(k) = update_double(r(k));
            end
        end

        function r = ldivide(a, b)
            r = rdivide(b, a);
        end

        function r = lt(a, b)
            for k = 1:numel(a)
                if (a(k).sign > b(k).sign)
                    r(k) = true;
                elseif (a(k).sign < b(k).sign)
                    r(k) = false;
                elseif (a(k).reciprocal < b(k).reciprocal)
                    r(k) = true;
                elseif (a(k).reciprocal > b(k).reciprocal)
                    r(k) = false;
                elseif (a(k).level < b(k).level)
                    r(k) = a(k).reciprocal;
                elseif (a(k).level > b(k).level)
                    r(k) = ~a(k).reciprocal;
                elseif (a(k).reciprocal)
                    r(k) = a(k).index < b(k).index;
                else
                    r(k) = a(k).index > b(k).index;
                end
            end
        end

        function r = gt(a, b)
            r = lt(b, a);
        end

        function r = le(a, b)
            r = lt(a, b) | eq(a, b);
        end

        function r = ge(a, b)
            r = gt(a, b) | eq(a, b);
        end

        function r = eq(a, b)
            r = (a.sign == b.sign) & (a.reciprocal == b.reciprocal) & ...
                (a.level == b.level) & (a.index == b.index);
        end

        function r = ne(a, b)
            r = ~eq(a,b);
        end

        function r = transpose(a)
          [nrows, ncolumns] = size(a);
          for i = 1:nrows
            for j = 1:ncolumns
              r(j,i) = a(i,j);
            end
          end
        end
    end

    methods (Static)

        % Create SLI arrays of zeros.
        % Use:
        %     zeros(m, lbits, ibits, 'sli')
        %     zeros(m,k, lbits, ibits, 'sli')
        function z = zeros(varargin)
            if (nargin == 3)
                for i = 1:varargin{1}
                    z(i) = sli(varargin{2}, varargin{3});
                    z(i).set_val(0);
                end
            elseif (nargin == 4)
                for i = 1:varargin{1}
                    for j = 1:varargin{2}
                        z(i,j) = sli(varargin{3}, varargin{4});
                        z(i,j) = z(i,j).set_val(0);
                    end
                end
            else
                error("Please specify 3 or 4 input arguments.");
            end
        end
    end

    methods (Access = private)
        % Check vector sizes are compatible, as per
        % https://uk.mathworks.com/help/matlab/matlab_prog/compatible-array-sizes-for-basic-operations.html
        function [a, b] = check_compatible_sizes(a, b)
              [m, n] = size(a); ael = numel(a);
              [k, l] = size(b); bel = numel(b);

              if (m == k && n == l)
                  return
              elseif (ael == 1)
                  temp = a;
                  a = b;
                  a(:, :) = temp;
              elseif (bel == 1)
                  temp = b;
                  b = a;
                  b(:,:) = temp;
              elseif (m==k && n == 1)
                  a = repmat(a, 1, l);
              elseif (m==k && l == 1)
                  b = repmat(b, 1, n);
              elseif (n==1 && k==1)
                  a = repmat(a, 1, l);
                  b = repmat(b, m, 1);
              elseif (m==1 && l==1)
                  a = repmat(a, k, 1);
                  b = repmat(b, 1, n);
              else
                  error('Arrays are not of compatibles sizes.');
              end
        end

        function obj = update_double(obj)
            for s = 1:numel(obj)
                obj(s) = update_sli(obj(s));
                if (obj(s).index == 0 && obj(s).level == 1 && obj(s).reciprocal == 0)
                    obj(s).value = 0;
                    continue;
                end
                obj(s).value = exp([obj(s).index]);
                for i = 2:obj(s).level
                    obj(s).value = exp(obj(s).value);
                end
                if ~obj(s).reciprocal
                    obj(s).value = 1/obj(s).value;
                end
                if obj(s).sign
                    obj(s).value = -obj(s).value;
                end
            end
        end

        function r = update_sli(obj)
            r = obj;
            if (obj.level > 2^obj.level_bits)
                r.level = 2^obj.level_bits;
            end
            r.index = round(2^obj.index_bits * ...
                obj.index)/2^(obj.index_bits);
            % Reciprocal flip if close to 1.
            if (r.index == 0 && r.level == 1 && obj.index ~= 0)
                r.reciprocal = 1;
            end
        end

        function r = li_le(a, b)
            if (a.sign > b.sign)
                r = true;
            elseif (a.sign < b.sign)
                r = false;
            elseif (a.level < b.level)
                r = true;
            elseif (a.level > b.level)
                r = false;
            else
                r = a.index <= b.index;
            end
        end

        % Following is a non-symmetric level-index addition operation
        % which is used for symmetric level-index * and / operations.
        %
        % Implementation after "Level-Index Arithmetic Operations"
        % by Clenshaw and Olver, SIAM J. Numer. Anal.24:2, 1987.
        function r = li_add(a, b)
            r = sli(a.level_bits, a.index_bits);
            if (a.level == 0)
                hzero = a.index + b.index;
                if (hzero < 1)
                    r.level = 0;
                    r.index = hzero;
                else
                    r.level = 1;
                    r.index = log(hzero);
                end
            else
                a_seq(a.level) = exp(-a.index);
                for (j = a.level-1:-1:1)
                    a_seq(j) = exp(-1/a_seq(j+1));
                end
                if (b.level >= 1)
                    b_seq(b.level) = a_seq(b.level)*exp(b.index);
                else
                    b_seq(1) = a_seq(1)*b.index;
                end
                for (j = b.level-1:-1:1)
                    b_seq(j) = exp(-(1-b_seq(j+1))/a_seq(j+1));
                end
                c_seq(1) = 1 + b_seq(1);
                for (j = 2:a.level)
                    c_seq(j)=1+a_seq(j)*log(c_seq(j-1));
                end
                r.level = a.level;
                r.index = a.index + log(c_seq(a.level));
                if (r.index >= 1)
                    r.level = r.level + 1;
                    r.index = log(r.index);
                end
            end
        end

        % Following is a non-symmetric level-index subtract operation
        % which is used for symmetric level-index * and / operations.
        %
        % Implementation after "Level-Index Arithmetic Operations"
        % by Clenshaw and Olver, SIAM J. Numer. Anal.24:2, 1987.
        function r = li_sub(a, b)
            r = sli(a.level_bits, a.index_bits);
            if (a.level == 0)
                r.level = 0;
                r.index = a.index - b.index;
            else
                a_seq(a.level) = exp(-a.index);
                for (j = a.level-1:-1:1)
                    a_seq(j) = exp(-1/a_seq(j+1));
                end
                if (b.level >= 1)
                    b_seq(b.level) = a_seq(b.level)*exp(b.index);
                else
                    b_seq(1) = a_seq(1)*b.index;
                end
                for (j = b.level-1:-1:1)
                    b_seq(j) = exp(-(1-b_seq(j+1))/a_seq(j+1));
                end
                c_seq(1) = 1 - b_seq(1);
                if (c_seq(1) < a_seq(1))
                    r.level = 0;
                    r.index = c_seq(1)/a_seq(1);
                    r = update_double(r);
                    return;
                end
                for (j = 2:a.level)
                    c_seq(j)=1+a_seq(j)*log(c_seq(j-1));
                    if (c_seq(j) < a_seq(j))
                        r.level = j-1;
                        r.index = c_seq(j)/a_seq(j);
                        r = update_double(r);
                        return;
                    end
                end
                r.level = a.level;
                r.index = a.index + log(c_seq(a.level));
            end
        end

        % Implementation after "The Symmetrix Level-Index System"
        % by Clenshaw and Turner, IMA J. Numer. Analysis, 8:4, 1988.
        function r = main_sli_algorithm(a, b, operation)
            r = a;
            % STEP 1
            a_seq(a.level) = exp(-a.index);
            for j=a.level-1:-1:1
                a_seq(j) = exp(-1/a_seq(j+1));
            end
            b_seq = [];
            % STEP 2
            % Small case
            if (a.reciprocal == 0) && (b.reciprocal == 0)
                if (a.level < b.level)
                    alpha_seq(b.level)=exp(-b.index);
                    for j=b.level-1:-1:a.level
                        alpha_seq(j) = exp(-1/alpha_seq(j+1));
                    end
                    beta_seq(a.level) = alpha_seq(a.level)/a_seq(a.level);
                else
                    beta_seq(a.level) = exp(a.index - b.index);
                end
                for j=a.level-1:-1:1
                    beta_seq(j) = ...
                        exp((beta_seq(j+1)-1)/(a_seq(j+1)*beta_seq(j+1)));
                end
                if strcmp(operation, 'add')
                    c_seq(1) = 1 + beta_seq(1);
                elseif strcmp(operation, 'sub')
                    c_seq(1) = 1 - beta_seq(1);
                end
            % Mixed case
            elseif (a.reciprocal == 1) && (b.reciprocal == 0)
                alpha_seq(b.level) = exp(-b.index);
                for j=b.level-1:-1:1
                    alpha_seq(j) = ...
                        exp(-1/alpha_seq(j+1));
                end
                if strcmp(operation, 'add')
                    c_seq(1) = 1 + a_seq(1)*alpha_seq(1);
                elseif strcmp(operation, 'sub')
                    c_seq(1) = 1 - a_seq(1)*alpha_seq(1);
                end
            % Big case
            else
                b_seq(b.level) = a_seq(b.level)*exp(b.index);
                for j=b.level-1:-1:1
                    b_seq(j) = ...
                        exp((b_seq(j+1)-1)/a_seq(j+1));
                end
                if (operation == 'add')
                    c_seq(1) = 1 + b_seq(1);
                elseif (operation == 'sub')
                    c_seq(1) = 1 - b_seq(1);
                end
            end
            % STEP 3
            h_index = 1;
            if (a.reciprocal == 1)
                if (c_seq(1) < a_seq(1))
                    h_index = 1;
                    r.reciprocal = 0;
                    h_seq(1) = -log(c_seq(1)/a_seq(1));
                elseif (a.level == 1)
                    h_index = 1;
                    h_seq(1) = a.index + log(c_seq(1));
                else
                    c_seq(2) = 1 + a_seq(2)*log(c_seq(1));
                    % STEP 4
                    for j = 2:a.level-1
                        if (c_seq(j) < a_seq(j))
                            r.level = j-1;
                            r.index = c_seq(j)/a_seq(j);
                            r = update_double(r);
                            return;
                        else
                            c_seq(j+1) = 1+a_seq(j+1)*log(c_seq(j));
                        end
                    end
                    if (c_seq(a.level) < a_seq(a.level))
                        r.level = a.level - 1;
                        r.index = c_seq(a.level)/a_seq(a.level);
                        r = update_double(r);
                        return;
                    else
                        h_seq(a.level) = a.index + ...
                            log(c_seq(a.level));
                        h_index = a.level;
                    end
                end
            else
                if (a_seq(1) * c_seq(1) > 1)
                    r.reciprocal = 1;
                    r.level = 1;
                    r.index = log(a_seq(1)*c_seq(1));
                    r = update_double(r);
                    return;
                elseif (a.level == 1)
                    h_seq(1) = a.index - log(c_seq(1));
                    h_index = 1;
                else
                    c_seq(2) = 1 - a_seq(2)*log(c_seq(1));
                    % STEP 4
                    for j = 2:a.level-1
                        if (c_seq(j) < a_seq(j))
                            r.level = j-1;
                            r.index = c_seq(j)/a_seq(j);
                            r = update_double(r);
                            return;
                        else
                            c_seq(j+1) = 1+a_seq(j+1)*log(c_seq(j));
                        end
                    end
                    if (c_seq(a.level) < a_seq(a.level))
                        r.level = a.level - 1;
                        r.index = c_seq(a.level)/a_seq(a.level);
                        r = update_double(r);
                        return;
                    else
                        h_seq(a.level) = a.index + ...
                            log(c_seq(a.level));
                        h_index = a.level;
                    end
                end
            end
            % STEP 5
            r.level = h_index;
            h = h_seq(h_index);
            while (h > 1)
                h = log(h);
                r.level = r.level + 1;
            end
            r.index = h;
            r = update_double(r);
        end
    end
end
