#include <blook/selftest.h>
#include <cstdio>

int main() {
    const int answer = blook_selftest_answer();
    std::printf("selftest_answer=%d\n", answer);
    return answer == 42 ? 0 : 1;
}
