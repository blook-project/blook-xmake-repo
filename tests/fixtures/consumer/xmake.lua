add_rules("mode.release")

-- SELFTEST_REPO_URL is set by .github/workflows/validate.yml to a throwaway git repo containing
-- tests/fixtures/selftest-repo (the registry must be a git repo, hence the file:// clone).
add_repositories("selftest " .. os.getenv("SELFTEST_REPO_URL"))
add_requires("blook-registry-selftest 0.1.0")

target("consumer")
    set_kind("binary")
    add_files("main.cpp")
    add_packages("blook-registry-selftest")
