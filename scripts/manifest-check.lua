-- Parse a single package manifest with xmake's package loader and dump facts.
--
-- Usage (from any configured xmake project directory):
--   xmake l scripts/manifest-check.lua <package_dir> <package_name>
--
-- Prints machine-readable lines consumed by scripts/validate-registry.ps1:
--   PARSE_OK <name>
--   URL <url template>
--   VERSION <version> <sha256>
--   VERSIONCOUNT <n>
--   ERROR <reason>

import("core.package.package")

function main(...)

    local args = table.pack(...)
    local packagedir = args[1]
    local packagename = args[2]
    if not packagedir or not packagename then
        print("ERROR missing arguments: <package_dir> <package_name>")
        return 1
    end

    local pkg, err = package.load_from_repository(packagename, packagedir)
    if not pkg then
        print("ERROR parse: " .. tostring(err))
        return 1
    end
    print("PARSE_OK " .. packagename)

    local urls = table.wrap(pkg:get("urls"))
    for _, url in ipairs(urls) do
        print("URL " .. url)
    end

    local versions = pkg:_versions_list()
    local count = 0
    if versions then
        for ver, sha in table.orderpairs(versions) do
            print("VERSION " .. ver .. " " .. tostring(sha))
            count = count + 1
        end
    end
    print("VERSIONCOUNT " .. count)
    return 0
end
