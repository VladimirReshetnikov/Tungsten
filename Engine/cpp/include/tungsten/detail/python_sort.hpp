#pragma once

#include <algorithm>
#include <cstddef>
#include <functional>
#include <utility>
#include <vector>

namespace tungsten::detail {

// A structural port of CPython 3.13's powersort-based list scheduler.
//
// Tungsten ordering predicates can mutate an Evaluator (Print, Throw, Abort,
// assignments, and so on), which makes the order of otherwise equivalent
// comparisons observable.  std::stable_sort therefore is not a compatible
// implementation for callable Wolfram comparators.
template<typename Item, typename Compare>
class PythonStableSorter {
public:
    PythonStableSorter(std::vector<Item> items, Compare compare)
        : items_(std::move(items)), compare_(std::move(compare)),
          list_length_(items_.size()) {}

    std::vector<Item> run() {
        if (list_length_ < 2) return std::move(items_);
        const auto minimum_run = compute_minimum_run(list_length_);
        std::size_t start = 0;
        std::size_t remaining = list_length_;
        while (remaining != 0) {
            const auto natural_length = count_run(start, remaining);
            const auto run_length = natural_length < minimum_run
                ? std::min(minimum_run, remaining) : natural_length;
            if (natural_length < minimum_run)
                binary_sort(start, run_length, natural_length);
            found_new_run(run_length);
            pending_runs_.push_back({start, run_length, 0});
            start += run_length;
            remaining -= run_length;
        }
        force_collapse_runs();
        return std::move(items_);
    }

private:
    static constexpr std::size_t maximum_minimum_run = 64;
    static constexpr std::size_t minimum_gallop = 7;

    struct PendingRun {
        std::size_t start;
        std::size_t length;
        std::size_t power;
    };

    bool compare_less(const Item& left, const Item& right) {
        return std::invoke(compare_, left, right);
    }

    bool compare_at(std::size_t left, std::size_t right) {
        return compare_less(items_[left], items_[right]);
    }

    static std::vector<Item> slice(
        const std::vector<Item>& values, std::size_t start,
        std::size_t width) {
        return std::vector<Item>(values.begin() + static_cast<std::ptrdiff_t>(start),
            values.begin() + static_cast<std::ptrdiff_t>(start + width));
    }

    static std::vector<Item> take(
        const std::vector<Item>& values, std::size_t width) {
        return slice(values, 0, std::min(width, values.size()));
    }

    static std::vector<Item> drop(
        const std::vector<Item>& values, std::size_t width) {
        return slice(values, std::min(width, values.size()),
            values.size() - std::min(width, values.size()));
    }

    static std::vector<Item> reversed(std::vector<Item> values) {
        std::reverse(values.begin(), values.end());
        return values;
    }

    static void append(
        std::vector<Item>& destination, const std::vector<Item>& source) {
        destination.insert(destination.end(), source.begin(), source.end());
    }

    static std::vector<Item> concatenate(
        std::vector<Item> first, const std::vector<Item>& second) {
        append(first, second);
        return first;
    }

    static std::vector<Item> concatenate(
        std::vector<Item> first, const std::vector<Item>& second,
        const std::vector<Item>& third) {
        append(first, second);
        append(first, third);
        return first;
    }

    void set_slice(std::size_t start, std::size_t width,
                   const std::vector<Item>& replacement) {
        auto first = items_.begin() + static_cast<std::ptrdiff_t>(start);
        auto last = first + static_cast<std::ptrdiff_t>(width);
        items_.erase(first, last);
        items_.insert(items_.begin() + static_cast<std::ptrdiff_t>(start),
            replacement.begin(), replacement.end());
    }

    void reverse_slice(std::size_t start, std::size_t width) {
        std::reverse(items_.begin() + static_cast<std::ptrdiff_t>(start),
            items_.begin() + static_cast<std::ptrdiff_t>(start + width));
    }

    std::size_t count_run(std::size_t start, std::size_t remaining) {
        if (remaining == 0) return 0;
        std::size_t length = 1;
        while (length < remaining) {
            if (compare_at(start + length, start + length - 1))
                return begin_descending(start, remaining, length);
            ++length;
        }
        return length;
    }

    std::size_t begin_descending(
        std::size_t start, std::size_t remaining, std::size_t length) {
        if (length > 1) {
            if (compare_at(start, start + length - 1)) return length;
            reverse_slice(start, length);
            return descend(start, remaining, length + 1, 0);
        }
        return descend(start, remaining, 2, 0);
    }

    std::size_t descend(std::size_t start, std::size_t remaining,
                        std::size_t length,
                        std::size_t equal_transitions) {
        while (length < remaining) {
            if (compare_at(start + length, start + length - 1)) {
                reverse_equal_suffix(start, length, equal_transitions);
                ++length;
                equal_transitions = 0;
                continue;
            }
            if (compare_at(start + length - 1, start + length))
                return finish_descending(
                    start, remaining, length, equal_transitions);
            ++length;
            ++equal_transitions;
        }
        return finish_descending(
            start, remaining, length, equal_transitions);
    }

    std::size_t finish_descending(
        std::size_t start, std::size_t remaining, std::size_t length,
        std::size_t equal_transitions) {
        reverse_equal_suffix(start, length, equal_transitions);
        reverse_slice(start, length);
        while (length < remaining
               && !compare_at(start + length, start + length - 1))
            ++length;
        return length;
    }

    void reverse_equal_suffix(std::size_t start, std::size_t length,
                              std::size_t equal_transitions) {
        if (equal_transitions == 0) return;
        const auto equal_count = equal_transitions + 1;
        reverse_slice(start + length - equal_count, equal_count);
    }

    void binary_sort(std::size_t start, std::size_t width,
                     std::size_t sorted_count) {
        if (sorted_count == 0) sorted_count = 1;
        for (std::size_t index = sorted_count; index < width; ++index) {
            const auto run_values = slice(items_, start, width);
            const auto pivot = run_values[index];
            std::size_t left = 0;
            std::size_t right = index;
            while (left < right) {
                const auto middle = left + (right - left) / 2;
                if (compare_less(pivot, run_values[middle])) right = middle;
                else left = middle + 1;
            }
            auto replacement = take(run_values, index);
            replacement.insert(
                replacement.begin() + static_cast<std::ptrdiff_t>(left), pivot);
            append(replacement, drop(run_values, index + 1));
            set_slice(start, width, replacement);
        }
    }

    static std::size_t compute_minimum_run(std::size_t value) {
        std::size_t shifted_bit = 0;
        while (value >= maximum_minimum_run) {
            shifted_bit = shifted_bit != 0 || value % 2 != 0 ? 1 : 0;
            value /= 2;
        }
        return value + shifted_bit;
    }

    static std::size_t power_loop(
        std::size_t first_start, std::size_t first_length,
        std::size_t second_length, std::size_t total_length) {
        std::size_t result = 0;
        auto midpoint_a = 2 * first_start + first_length;
        auto midpoint_b = 2 * first_start + 2 * first_length + second_length;
        while (true) {
            if (midpoint_a >= total_length) {
                ++result;
                midpoint_a = 2 * (midpoint_a - total_length);
                midpoint_b = 2 * (midpoint_b - total_length);
            } else if (midpoint_b >= total_length) {
                return result + 1;
            } else {
                ++result;
                midpoint_a *= 2;
                midpoint_b *= 2;
            }
        }
    }

    void found_new_run(std::size_t new_length) {
        if (pending_runs_.empty()) return;
        const auto& newest = pending_runs_.back();
        const auto power = power_loop(newest.start, newest.length,
            new_length, list_length_);
        while (pending_runs_.size() > 1
               && pending_runs_[pending_runs_.size() - 2].power > power)
            merge_at(pending_runs_.size() - 2);
        pending_runs_.back().power = power;
    }

    void force_collapse_runs() {
        while (pending_runs_.size() > 1) {
            auto index = pending_runs_.size() - 2;
            if (index > 0
                && pending_runs_[index - 1].length
                    < pending_runs_[index + 1].length)
                --index;
            merge_at(index);
        }
    }

    void merge_at(std::size_t run_index) {
        const auto first_run = pending_runs_[run_index];
        const auto second_run = pending_runs_[run_index + 1];
        pending_runs_[run_index].length
            = first_run.length + second_run.length;
        pending_runs_.erase(
            pending_runs_.begin() + static_cast<std::ptrdiff_t>(run_index + 1));

        auto first_values = slice(items_, first_run.start, first_run.length);
        const auto second_values
            = slice(items_, second_run.start, second_run.length);
        const auto skipped_first = gallop_right(
            second_values.front(), first_values, first_values.size(), 0);
        first_values = drop(first_values, skipped_first);
        if (first_values.empty()) return;
        const auto kept_second = gallop_left(first_values.back(),
            second_values, second_values.size(), second_values.size() - 1);
        if (kept_second == 0) return;
        const auto retained_second = take(second_values, kept_second);
        const auto merged = first_values.size() <= retained_second.size()
            ? merge_low(first_values, retained_second)
            : merge_high(first_values, retained_second);
        set_slice(first_run.start + skipped_first,
            first_values.size() + retained_second.size(), merged);
    }

    std::size_t gallop_left(
        const Item& key, const std::vector<Item>& values,
        std::size_t width, std::size_t hint) {
        std::size_t last_offset = 0;
        std::size_t offset = 1;
        if (compare_less(values[hint], key)) {
            const auto maximum_offset = width - hint;
            while (offset < maximum_offset
                   && compare_less(values[hint + offset], key)) {
                last_offset = offset;
                offset = 2 * offset + 1;
            }
            offset = std::min(offset, maximum_offset);
            last_offset += hint;
            offset += hint;
        } else {
            const auto maximum_offset = hint + 1;
            while (offset < maximum_offset
                   && !compare_less(values[hint - offset], key)) {
                last_offset = offset;
                offset = 2 * offset + 1;
            }
            offset = std::min(offset, maximum_offset);
            const auto translated_last = hint - offset;
            const auto translated_offset = hint - last_offset;
            last_offset = translated_last;
            offset = translated_offset;
        }
        ++last_offset;
        while (last_offset < offset) {
            const auto middle = last_offset + (offset - last_offset) / 2;
            if (compare_less(values[middle], key)) last_offset = middle + 1;
            else offset = middle;
        }
        return offset;
    }

    std::size_t gallop_right(
        const Item& key, const std::vector<Item>& values,
        std::size_t width, std::size_t hint) {
        std::size_t last_offset = 0;
        std::size_t offset = 1;
        if (compare_less(key, values[hint])) {
            const auto maximum_offset = hint + 1;
            while (offset < maximum_offset
                   && compare_less(key, values[hint - offset])) {
                last_offset = offset;
                offset = 2 * offset + 1;
            }
            offset = std::min(offset, maximum_offset);
            const auto translated_last = hint - offset;
            const auto translated_offset = hint - last_offset;
            last_offset = translated_last;
            offset = translated_offset;
        } else {
            const auto maximum_offset = width - hint;
            while (offset < maximum_offset
                   && !compare_less(key, values[hint + offset])) {
                last_offset = offset;
                offset = 2 * offset + 1;
            }
            offset = std::min(offset, maximum_offset);
            last_offset += hint;
            offset += hint;
        }
        ++last_offset;
        while (last_offset < offset) {
            const auto middle = last_offset + (offset - last_offset) / 2;
            if (compare_less(key, values[middle])) offset = middle;
            else last_offset = middle + 1;
        }
        return offset;
    }

    static std::vector<Item> finish_low(
        const std::vector<Item>& output_reversed,
        const std::vector<Item>& first,
        const std::vector<Item>& second) {
        return concatenate(reversed(output_reversed), first, second);
    }

    static std::vector<Item> copy_second_then_first(
        const std::vector<Item>& output_reversed,
        const std::vector<Item>& first,
        const std::vector<Item>& second) {
        return concatenate(reversed(output_reversed), second, first);
    }

    std::vector<Item> merge_low(
        const std::vector<Item>& first_values,
        const std::vector<Item>& second_values) {
        if (second_values.empty()) return first_values;
        std::vector<Item> output_reversed{second_values.front()};
        const auto second_tail = drop(second_values, 1);
        if (second_tail.empty())
            return finish_low(output_reversed, first_values, {});
        if (first_values.size() == 1)
            return copy_second_then_first(
                output_reversed, first_values, second_tail);
        return merge_low_straight(minimum_gallop_, first_values,
            second_tail, output_reversed, 0, 0);
    }

    std::vector<Item> merge_low_straight(
        std::size_t gallop_limit, std::vector<Item> first,
        std::vector<Item> second, std::vector<Item> output_reversed,
        std::size_t first_wins, std::size_t second_wins) {
        while (true) {
            if (compare_less(second.front(), first.front())) {
                output_reversed.insert(
                    output_reversed.begin(), second.front());
                second.erase(second.begin());
                ++second_wins;
                first_wins = 0;
                if (second.empty())
                    return finish_low(output_reversed, first, {});
                if (second_wins >= gallop_limit)
                    return merge_low_galloping(
                        gallop_limit + 1, first, second, output_reversed);
            } else {
                output_reversed.insert(
                    output_reversed.begin(), first.front());
                first.erase(first.begin());
                ++first_wins;
                second_wins = 0;
                if (first.size() == 1)
                    return copy_second_then_first(
                        output_reversed, first, second);
                if (first_wins >= gallop_limit)
                    return merge_low_galloping(
                        gallop_limit + 1, first, second, output_reversed);
            }
        }
    }

    std::vector<Item> merge_low_galloping(
        std::size_t gallop_limit, std::vector<Item> first,
        std::vector<Item> second, std::vector<Item> output_reversed) {
        while (true) {
            const auto reduced_limit = std::max<std::size_t>(1, gallop_limit - 1);
            minimum_gallop_ = reduced_limit;
            const auto first_count
                = gallop_right(second.front(), first, first.size(), 0);
            const auto first_block = take(first, first_count);
            first = drop(first, first_count);
            auto after_first = concatenate(
                reversed(first_block), output_reversed);
            if (first.size() <= 1) {
                if (first.empty()) return finish_low(after_first, {}, second);
                return copy_second_then_first(after_first, first, second);
            }

            after_first.insert(after_first.begin(), second.front());
            second.erase(second.begin());
            if (second.empty()) return finish_low(after_first, first, {});

            const auto second_count
                = gallop_left(first.front(), second, second.size(), 0);
            const auto second_block = take(second, second_count);
            second = drop(second, second_count);
            auto output_after_block = concatenate(
                reversed(second_block), after_first);
            if (second.empty())
                return finish_low(output_after_block, first, {});

            output_after_block.insert(output_after_block.begin(), first.front());
            first.erase(first.begin());
            if (first.size() == 1)
                return copy_second_then_first(
                    output_after_block, first, second);
            if (first_count >= minimum_gallop
                || second_count >= minimum_gallop) {
                gallop_limit = reduced_limit;
                output_reversed = std::move(output_after_block);
                continue;
            }
            const auto penalized_limit = reduced_limit + 1;
            minimum_gallop_ = penalized_limit;
            return merge_low_straight(penalized_limit, first, second,
                output_after_block, 0, 0);
        }
    }

    static std::vector<Item> finish_high(
        const std::vector<Item>& first, const std::vector<Item>& second,
        const std::vector<Item>& suffix) {
        return concatenate(first, second, suffix);
    }

    static std::vector<Item> copy_first_then_second(
        const std::vector<Item>& first, const std::vector<Item>& second,
        const std::vector<Item>& suffix) {
        return concatenate(second, first, suffix);
    }

    std::vector<Item> merge_high(
        const std::vector<Item>& first_values,
        const std::vector<Item>& second_values) {
        if (first_values.empty()) return second_values;
        const auto first_tail = take(first_values, first_values.size() - 1);
        std::vector<Item> suffix{first_values.back()};
        if (first_tail.empty()) return concatenate(second_values, suffix);
        if (second_values.size() == 1)
            return concatenate(first_tail, second_values, suffix);
        return merge_high_straight(minimum_gallop_, first_tail,
            second_values, suffix, 0, 0);
    }

    std::vector<Item> merge_high_straight(
        std::size_t gallop_limit, std::vector<Item> first,
        std::vector<Item> second, std::vector<Item> suffix,
        std::size_t first_wins, std::size_t second_wins) {
        while (true) {
            if (compare_less(second.back(), first.back())) {
                suffix.insert(suffix.begin(), first.back());
                first.pop_back();
                ++first_wins;
                second_wins = 0;
                if (first.empty()) return finish_high({}, second, suffix);
                if (first_wins >= gallop_limit)
                    return merge_high_galloping(
                        gallop_limit + 1, first, second, suffix);
            } else {
                suffix.insert(suffix.begin(), second.back());
                second.pop_back();
                ++second_wins;
                first_wins = 0;
                if (second.size() == 1)
                    return copy_first_then_second(first, second, suffix);
                if (second_wins >= gallop_limit)
                    return merge_high_galloping(
                        gallop_limit + 1, first, second, suffix);
            }
        }
    }

    std::vector<Item> merge_high_galloping(
        std::size_t gallop_limit, std::vector<Item> first,
        std::vector<Item> second, std::vector<Item> suffix) {
        while (true) {
            const auto reduced_limit = std::max<std::size_t>(1, gallop_limit - 1);
            minimum_gallop_ = reduced_limit;
            const auto first_boundary = gallop_right(
                second.back(), first, first.size(), first.size() - 1);
            const auto first_block = drop(first, first_boundary);
            first = take(first, first_boundary);
            auto after_first = concatenate(first_block, suffix);
            const auto first_count = first_block.size();
            if (first.empty()) return finish_high({}, second, after_first);

            after_first.insert(after_first.begin(), second.back());
            second.pop_back();
            if (second.size() == 1)
                return copy_first_then_second(first, second, after_first);

            const auto second_boundary = gallop_left(
                first.back(), second, second.size(), second.size() - 1);
            const auto second_block = drop(second, second_boundary);
            second = take(second, second_boundary);
            auto suffix_after_block = concatenate(second_block, after_first);
            const auto second_count = second_block.size();
            if (second.size() <= 1) {
                if (second.empty())
                    return finish_high(first, {}, suffix_after_block);
                return copy_first_then_second(
                    first, second, suffix_after_block);
            }

            suffix_after_block.insert(suffix_after_block.begin(), first.back());
            first.pop_back();
            if (first.empty())
                return finish_high({}, second, suffix_after_block);
            if (first_count >= minimum_gallop
                || second_count >= minimum_gallop) {
                gallop_limit = reduced_limit;
                suffix = std::move(suffix_after_block);
                continue;
            }
            const auto penalized_limit = reduced_limit + 1;
            minimum_gallop_ = penalized_limit;
            return merge_high_straight(penalized_limit, first, second,
                suffix_after_block, 0, 0);
        }
    }

    std::vector<Item> items_;
    Compare compare_;
    std::size_t minimum_gallop_ = minimum_gallop;
    std::vector<PendingRun> pending_runs_;
    std::size_t list_length_;
};

template<typename Item, typename Compare>
std::vector<Item> python_stable_sort(
    std::vector<Item> items, Compare compare) {
    return PythonStableSorter<Item, Compare>(
        std::move(items), std::move(compare)).run();
}

} // namespace tungsten::detail
