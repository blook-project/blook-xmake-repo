-- blook-project package: blook-drv
-- Hardened hypervisor driver with user-mode EPT and hardware-breakpoint hook SDK
--
-- Artifact: GitHub Release asset of blook-project/blook-drv
-- Layout:   <pkg>-<version>-windows-x64.zip  { include/, lib/, bin/, scripts/, docs }
-- hashes:   versions.txt  ("<version> <sha256>", updated by scripts/publish-registry.ps1)
package("blook-drv")
    set_homepage("https://github.com/blook-project/blook-drv")
    set_description("Hardened hypervisor driver with user-mode EPT and hardware-breakpoint hook SDK")
    set_license("MIT")

    add_urls("https://github.com/blook-project/blook-drv/releases/download/v$(version)/blook-drv-$(version)-windows-x64.zip")
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
        for _, subdir in ipairs({ "bin/x64", "bin" }) do
            if os.isdir(path.join(installdir, subdir)) then
                package:add("bindirs", path.join(installdir, subdir))
            end
        end
    end)
