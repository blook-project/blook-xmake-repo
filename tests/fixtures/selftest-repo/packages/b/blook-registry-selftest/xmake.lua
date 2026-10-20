-- Self-test package for the blook-project xmake registry.
-- It is NOT part of the product registry: it lives under tests/fixtures/ and is installed by
-- .github/workflows/validate.yml from a real GitHub Release asset of this repository
-- (tag selftest-v0.1.0), which proves URL resolution + sha256 verification + on_install.
package("blook-registry-selftest")
    set_homepage("https://github.com/blook-project/blook-xmake-repo")
    set_description("blook-xmake-repo self-test package (fixture)")
    set_license("MIT")

    add_urls("https://github.com/blook-project/blook-xmake-repo/releases/download/selftest-v0.1.0/blook-registry-selftest-0.1.0.zip")
    add_versionfiles("versions.txt")

    on_install("windows", function (package)
        local installdir = package:installdir()
        for _, entry in ipairs({ "include", "bin" }) do
            if os.isdir(entry) then
                os.cp(entry, installdir)
            end
        end
        for _, docfile in ipairs(os.files("*.md")) do
            os.cp(docfile, installdir)
        end
    end)

    on_load(function (package)
        local installdir = package:installdir()
        if os.isdir(path.join(installdir, "include")) then
            package:add("includedirs", path.join(installdir, "include"))
        end
        if os.isdir(path.join(installdir, "bin", "x64")) then
            package:add("bindirs", path.join(installdir, "bin", "x64"))
        end
    end)
