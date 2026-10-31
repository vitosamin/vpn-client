# Bundled RU geo lists

The default region rule (region `ru`) is built from these files, so RU sites take the direct
outbound on the first connect: nothing is downloaded, GitHub is not needed, and the rule is a plain
sing-box rule in the config the core builds. See `docs/impl-geo.md` in the app repo for the whole
picture.

| File | Items | Source |
| --- | --- | --- |
| `ru_domain.txt` | exact domains of `geosite-ru` | `hiddify-geo/rule-set/country/geosite-ru.srs` |
| `ru_domain_suffix.txt` | domain suffixes of `geosite-ru` | same |
| `ru_ip_cidr.txt` | CIDRs of `geoip-ru` | `hiddify-geo/rule-set/country/geoip-ru.srs` |

One item per line, no comments, sorted and de-duplicated. Last update: the rule-set revision
downloaded on 2026-10-31:

| Source | Size | SHA-256 |
| --- | --- | --- |
| `geosite-ru.srs` | 15 684 B | `27d6f357ff99b2149521016d6fb6fe4cf7dbe4f74b0246c21adfa92466dedb8f` |
| `geoip-ru.srs` | 104 905 B | `abf28d4e8365ef2ff9ebd76f7ccbd2c45653b3b9ecd3a1d7c699ec0c30efdebf` |

## Updating

```bash
scripts/update-geo-rules.sh          # downloads the rule-sets and rewrites the three files
scripts/update-geo-rules.sh --check  # compares them with a fresh download, writes nothing
```

The script fetches the `.srs` files from
`https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country/`, decompiles them with
`sing-box rule-set decompile` (a sing-box release binary is needed; the script downloads one if it
is not on `PATH`), and flattens the source format into the text files. It needs `bash`, `curl` and
`python3`.

After an update, run `flutter test test/features/route_rules` and rebuild the APK: the lists are
assets, so a new list only reaches users with a new app version. That is the trade-off for working
without a network.
