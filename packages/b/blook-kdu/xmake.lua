-- blook-project package: blook-kdu
-- Self-contained Windows kernel driver exploitation toolkit with manual mapping, kernel payload and SDK
--
-- Artifact: GitHub Release asset of blook-project/blook-kdu
-- Layout:   <pkg>-<version>-windows-x64.zip  { include/, lib/, bin/, scripts/, docs }
-- hashes:   versions.txt  ("<version> <sha256>", updated by scripts/publish-registry.ps1)
package("blook-kdu")
    set_homepage("https://github.com/blook-project/blook-kdu")
    set_description("Self-contained Windows kernel driver exploitation toolkit with manual mapping, kernel payload and SDK")
    set_license("MIT")

    add_urls("https://github.com/blook-project/blook-kdu/releases/download/v$(version)/blook-kdu-$(version)-windows-x64.zip")
    add_versionfiles("versions.txt")

    on_install("windows", "x64", function (package)
        local installdir = package:installdir()
        for _, entry in ipairs({ "include", "lib", "bin", "share", "scripts" }) do
            if os.isdir(entry) then
                os.cp(entry, installdir)
            end
        end
        for _, docfile in ipairs(os.files("*.md")) do
            os.cp(docfile, installdir)
        end
        if os.isfile("LICENSE") then
            os.cp("LICENSE", installdir)
        end
    end)

    on_load(function (package)
        local installdir = package:installdir()
        if os.isdir(path.join(installdir, "include")) then
            package:add("includedirs", path.join(installdir, "include"))
        end
        for _, subdir in ipairs({ "lib/x64", "lib" }) do
            if os.isdir(path.join(installdir, subdir)) then
                package:add("linkdirs", path.join(installdir, subdir))
            end
        end
        for _, subdir in ipairs({ "bin/x64", "bin" }) do
            if os.isdir(path.join(installdir, subdir)) then
                package:add("bindirs", path.join(installdir, subdir))
            end
        end
    end)
