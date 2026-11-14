# 012 — Energia dos notebooks-servidor (tampa, bateria, RTC)

- **Status:** aceito
- **Data:** 2026-11-14
- **Atualiza:** [011](011-syncthing-nas-ansible.md), que passa a ter uma segunda exceção ao "o Ansible não toca no NAS"
- **Issue:** #15

## Contexto

O cluster e o NAS rodam em notebooks com a tampa fechada.

- **2026-11-13, das 16:20 às 17:37:** o notebook do k3s ficou mais de 15 min na bateria, e o GNOME o suspendeu (`sleep-inactive-battery-type 'suspend'`, 900 s). O role `power` só tratava a tampa no logind. O cluster inteiro caiu: o CNPG perdeu o lease, o coletor descartou dados e o Loki recusou 1h de logs atrasados.
- **NAS (ThinkPad T400):** a tampa fechada com `HandleLidSwitch=suspend`, somada aos alvos de sono que o OMV mascara, gera cerca de 1.600 linhas por hora de "Failed to execute suspend operation: Permission denied". Isso é 79% dos erros do Loki.

A issue #15 pede:
- nunca suspender, nem na tomada nem na bateria;
- limitar a carga a 80–90%;
- desligar com segurança com bateria baixa;
- de preferência, religar sozinho quando a energia voltar.

Restrições do hardware:
- **Acer A515-51G (BIOS V2.02):** o `acer_wmi` não expõe `charge_control_end_threshold`. O GUID WMI de bateria (`79772EC5-…`) existe, mas o método `WMBE` do SSDT só implementa a função 0x13 (ler informações). As funções 20 e 21, que leem e gravam o "health mode" do Acer Care Center, caem no `default` e devolvem erro. Testado em 2026-11-14 com o [acer-wmi-battery](https://github.com/frederik-h/acer-wmi-battery) v0.2.0 pelo DKMS: o `modprobe` falha com "buffer of unexpected length 4", o mesmo da issue upstream #55 (TravelMate da mesma geração). O UPower vem com `CriticalPowerAction=HybridSleep` em 2%.
- **T400 (BIOS 3.23):** os thresholds do `thinkpad_acpi` não funcionam nesse modelo, e o `tp_smapi` exigiria o kernel 7.2 com headers no pendrive do sistema. A bateria guarda 2,4 de 37,4 Wh (6%).
- **Ligar ao conectar o AC:** nenhum dos dois BIOS tem a opção. Os dois expõem `/sys/class/rtc/rtc0/wakealarm`.

## Decisão

O role `power` vale para os dois notebooks: no play do k3s e num play `hosts: nas`, com `nas_power_enabled`.

- **Nunca suspender:**
  - `HandleLidSwitch*=ignore` no logind, para tomada, bateria e dock;
  - alvos `sleep`, `suspend`, `hibernate`, `hybrid-sleep` e `suspend-then-hibernate` mascarados;
  - onde há GNOME, o dconf do sistema trava `sleep-inactive-{ac,battery}-type='nothing'`.
- **Guardião de energia (`homelab-power-guard.service`):** um serviço contínuo (não um timer, para não gerar duas linhas de journal a cada 30 s) lê `/sys/class/power_supply` a cada 30 s.
  - Na bateria, registra "energia externa caiu" uma vez. O alerta `host-on-battery` avisa por e-mail.
  - Com `capacity <= power_shutdown_percent` (10%), arma o RTC, grava um marcador e desliga pelo systemd, que para o k3s e o Postgres em ordem.
  - O UPower do Acer passa a `CriticalPowerAction=PowerOff`, só como rede de segurança.
- **Religar pelo RTC:** antes de desligar, o guardião programa o RTC para daqui a `power_rtc_wake_interval` (30 min). No boot, o `homelab-power-gate.service` roda antes da rede, do k3s e do samba, **só se o marcador existir**: se a energia voltou, o boot segue; se não, desliga de novo e rearma. Um boot manual (sem marcador) nunca é derrubado.
- **Sem limite de carga** (item 2 da issue): nenhum dos dois firmwares tem um mecanismo, e o role não instala módulo nem DKMS. As baterias ficam em 100% na tomada, o que acelera o desgaste, mas o guardião não depende da capacidade total.
- **NAS:** a segunda exceção ao "Ansible não toca o NAS", com o mesmo acesso do ADR 011 (root SSH, grupo `nas`, ausente no CI).

## Consequências

- **Bateria do NAS:** dura menos de um minuto a 10%, então o desligamento dele é "melhor esforço" até a troca (Sanyo 42T4654 ou equivalente).
- **RTC:** religar depende de o BIOS acordar de S5 pelo RTC, o que é testado com alguém em casa. Onde não funcionar, `power_rtc_wake_interval: 0` naquele host.
- **Ciclos de boot:** cada boot do gate na bateria gasta um pouco de carga, mas o desligamento acontece antes da rede e do k3s, então o consumo é pequeno.
- **Limite de carga, se um dia houver:** a bateria nova do NAS reabre o `tp_smapi` (exige os headers do kernel no pendrive). Um notebook de cluster mais novo (Acer a partir de ~2019) teria o "health mode" pelo acer-wmi-battery.
