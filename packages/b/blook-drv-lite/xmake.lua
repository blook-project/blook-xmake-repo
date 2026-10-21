-- blook-project package: blook-drv-lite
-- Lite manual-map kernel driver and SDK (memory r/w, DSE, object handles, InfinityHook)
--
-- Artifact: GitHub Release asset of blook-project/blook-drv-lite
-- Layout:   <pkg>-<version>-windows-x64.zip  { include/, lib/, bin/, scripts/, docs }
-- hashes:   versions.txt  ("<version> <sha256>", updated by scripts/publish-registry.ps1)
package("blook-drv-lite")
    set_homepage("https://github.com/blook-project/blook-drv-lite")
    set_description("Lite manual-map kernel driver and SDK (memory r/w, DSE, object handles, InfinityHook)")
    set_license("MIT")

    add_urls("https://github.com/blook-project/blook-drv-lite/releases/download/v$(version)/blook-drv-lite-$(version)-windows-x64.zip")
    add_versionfiles("versions.txt")

    on_install("windows", function (package)
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
        -- ship a default link for consumers when the SDK lib is present
        if os.isfile(path.join(installdir, "lib", "x64", "drvlite-sdk.lib")) or
           os.isfile(path.join(installdir, "lib", "drvlite-sdk.lib")) then
            package:add("links", "drvlite-sdk")
        end        for _, subdir in ipairs({ "bin/x64", "bin" }) do
            if os.isdir(path.join(installdir, subdir)) then
                package:add("bindirs", path.join(installdir, subdir))
            end
        end
    end)

