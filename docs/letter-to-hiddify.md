# Черновик письма в Hiddify (коммерческое разрешение)

**Кому:** Hiddify (GitHub issue в `hiddify/hiddify-app` либо support-адрес проекта)
**Тема:** Commercial use permission for a localized Hiddify fork (VPN service in Russia)

---

Hello Hiddify team,

We are building a small VPN service in Russia and would like to use
**hiddify-app** as the base for our mobile client. We respect your license: we
will publish our fork on GitHub (as required by section 1), keep it up to date,
release only through GitHub Actions (section 2), keep attribution and the
license link, avoid any Hiddify-like name or UI (section 5), and publish all our
changes under the same license (section 7).

The only point we cannot satisfy is section 6 — **NonCommercial Use Only** —
because the client will be distributed as part of a paid service: the user pays
for a subscription, receives an activation code, and the app downloads their
server profile from our 3x-ui panel. The app itself would be free to download,
but it advertises and gives access to the paid service.

Could you please tell us:

1. Whether you can grant **prior written consent** for commercial use of a fork
   (and under what conditions — mandatory plan/branding or a link back to
   Hiddify?).
2. If consent is not possible, whether you could point us to a licensed path,
   e.g. the commercial license for sing-box, or a whitelabel arrangement.

We would also be happy to contribute fixes back to upstream — our changes are
small (activation-code onboarding, priority-based failover, RU-direct routing
rules).

Thank you,
Vitaly

---

## Заметки

- Отправлять — только после решения владельца; в письме нет ни IP, ни доменов,
  ни данных панели.
- Параллельно стоит уточнить у SagerNet условия коммерческой лицензии sing-box
  (на случай перехода на вариант B/C).
- Ответ (или его отсутствие через ~2 недели) — критерий выбора пути в
  [ADR-001](adr-001-base-and-license.md), п. 4.
