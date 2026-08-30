# Reskin pixel-art — estado da migração

Branch `telaLOGIN`. Documento de continuidade: leia isto primeiro ao retomar em outra máquina.

## Contexto

A skin pixel-art (sprites cobre/marrom + fonte `silkscreen-16`) substitui a skin cinza do
Tibia em todo o cliente. A estratégia da branch é **reskinar os sprites genéricos
compartilhados** (`/images/ui/popupwindow`, `checkbox`, `buttons`, …) em vez de criar uma
pasta de sprites dedicada a cada tela — decisão registrada no commit `b0b9548`.

O ponto de alavanca da fonte é `&var-cip-font` em `data/styles/0-vars.otui`. Essa variável
era **referenciada 1510 vezes em 155 arquivos mas nunca definida**: o OTML resolvia para
string vazia e `UIWidget::setFont` caía em `getDefaultFont()` (= `verdana-11px-antialised`).
Defini-la virou todas essas telas de uma vez.

## O problema central da migração

`silkscreen-16` é **~1,7x mais largo** que `verdana-11px-antialised`. Todo layout com largura
fixa calibrada para o Verdana corta texto quando recebe a fonte nova.

Não há atalho: o atlas da silkscreen **não** é um 8px escalado 2x (21,7% dos blocos 2x2
divergem), então não dá para gerar uma variante estreita. E não dá para registrar uma fonte
nova: o atlas de texto é fixo em 2048x2048 (`Atlas::init`, sem `BIG_FONTS`) e já está cheio —
foi preciso desativar `Verdana-11px-italic.otfont` para caber a silkscreen.

---

## Estado atual: todas as telas alcançáveis auditam limpas

`tools/uisweep.ps1` abre 28 janelas no cliente rodando e audita cada uma. **28 de 28 limpas.**
A varredura estática (`tools/otui-textfit.ps1`) reporta **0 estouros**. `tools/otui-lint.js`
passa nos 473 arquivos OTML do cliente.

A única janela que não abre é `npctrade`: o Lua dela quer dados de troca vindos do servidor,
não é defeito de UI.

### O que foi corrigido, por classe de defeito

| Classe | Onde estava | Correção |
|---|---|---|
| 9-slice da moldura errado | `NewWindow`/`WindowCyclopedia`/`WindowPodium`, ~68 otui | borda medida na arte: 6 nas laterais, 30 no topo. Antes o anel `#9a6651` e o divisor preto se **repetiam** por toda janela |
| Botões na fonte de 8px | `Button`, `QtButton`, ~680 instâncias | `$var-cip-font`; 251 botões alargados por medição |
| Título em Verdana | `Window` (base de `MainWindow`, 64 arquivos) | `$var-cip-font` |
| Combobox transbordando à esquerda | estilo `ComboBox` | `text-offset` de -15 para -10 (metade da seta, não a seta inteira) |
| Rótulo cresce contra valor | questlog, forge, market, highscores | o par ancorado junto, crescendo para o lado que tem espaço |
| Alinhamento falso por `text-offset` negativo | highscores, character list | `text-align: left` de verdade |
| Título de mini-janela cortado | 13 janelas da sidebar | títulos encurtados contra o espaço real (~119px) |
| Nome de outfit quebrando no meio | 18 de 132 | margem do rótulo e tile próprio de 120px; restam 3 |
| Colunas desalinhadas | character list | cabeçalho e linha nos mesmos limites |
| Arte cinza dentro de moldura nova | 260 sprites, 800+ literais hex | rampa de luminância para a paleta fechada |
| Texto fora da fonte pixel | `CheckBox`, `ButtonBox`, listas, cabeçalhos, HUD | 9 → **22 de 22 janelas 100% silkscreen**; HUD também |
| Variável de fonte nunca definida | 6 aliases, 39 usos | mesmo bug de `&var-cip-font`: OTML resolvia vazio e caía no Verdana |
| Branco fora da paleta | 70 valores de texto | `#ebbf90`; barra de progresso e tint de item ficam |

Depois disso restam **24 sprites cinza referenciados**, e são ícones
(`icon-questionmark`, `back-icons`, `copy-all`, `paste`, `hide-pin`, `item-blessed`),
não chrome. A rampa neles custaria legibilidade sem ganhar nada.

O HUD ficou na mesma paleta: barra do topo, slots da action bar, abas do chat, sidebar,
minimapa. A arte de jogo (criaturas, itens, a bússola) mantém as cores dela, e as barras de
vida e mana continuam verde e azul — a rampa só toca pixel cinza neutro.

---

## As ferramentas (é o que fica)

Tudo em `tools/` da raiz do workspace, porque atravessa repositórios.

### Pilotar o cliente rodando

```powershell
.\tools\uidrive.ps1 -Action start          # sobe o cliente com o mod de dev injetado
.\tools\uidrive.ps1 -Action lua -Script "return UID.windows()"
.\tools\uidrive.ps1 -Action shot -Out shot.png
.\tools\uiplay.ps1                          # start -> autentica -> entra no mundo
.\tools\uiwin.ps1 -Open "modules.game_forge.show()" -Name forge -OutDir shots
.\tools\uisweep.ps1 -OutDir shots           # as 28 janelas, uma a uma
```

O mod fica em `tools/uidriver/` e o `uidrive.ps1` copia para `client/mods/zz_uidriver/` ao
subir. O cliente **não** versiona essa pasta. Screenshot sai por `g_app.doScreenshot`, que
grava o framebuffer sem borda de janela — pixel (0,0) é o canto do conteúdo, e a imagem entra
direto no `probe.js`.

### A auditoria em runtime (`UID.audit`)

É a metade que a varredura estática não faz. Reporta quatro coisas:

- `ESTOURA` — texto pintado fora do próprio widget, e quanto é cortado de cada lado
- `COLIDE` — dois textos pintados um sobre o outro
- `ESCAPA` — texto fora da área útil da janela
- `SAI-RECT` — filho cujo retângulo sai da área útil

Ela mede onde os glifos **realmente caem**, e isso exigiu ler o engine em vez de supor:

- `BitmapFont::calculateDrawTextCoords` alinha os glifos dentro de `screenCoords`. Texto
  centralizado **não** começa em `rect.x + text-offset`.
- A mesma função **descarta** glifos fora de `screenCoords` e corta os que cruzam a borda.
  Texto não pinta por cima do vizinho: ele é **cortado**.
- Widget dentro de container com `clipping` só pinta onde o container mostra.
- `getTextSize()` devolve a caixa nominal de 16px, mas quase todo glifo da silkscreen para na
  linha 13 — dois rótulos a 13px de distância não se tocam.

### Medir e corrigir largura

```powershell
.\tools\otui-textfit.ps1                    # varre modules/, mods/ e data/styles
.\tools\otui-fitfix.ps1 -Types '^Button$'   # aplica as larguras que ela pediu
```

O `otui-fitfix.ps1` existe para não repetir um acidente: uma passagem anterior casou por
número de linha, pegou o `size:` do bloco **seguinte** e redimensionou o widget errado no
`cyclopedia.otui`. Ele só escreve quando o valor encontrado bate com o que a varredura
reportou, e procura só em linhas na indentação do próprio widget.

### Paleta

```powershell
node tools\pixelui\palettecheck.js client\data\images\ui   # quanto de cada sprite é cinza
node tools\pixelui\greyrefs.js client                      # cruzado com quem referencia
node tools\pixelui\regrade.js in.png out.png               # um sprite
node tools\pixelui\regrade-batch.js client --apply         # chrome cinza + referenciado
node tools\pixelui\regrade-otui.js client --apply --text   # literais hex em .otui e .lua
```

O `regrade` **não redesenha**: mapeia a luminância de cada pixel para a paleta fechada
(`#000000 #150e0c #231815 #33231d #4e2f24 #9a6651 #c68f66 #ebbf90`). A arte antiga é
dessaturada, então a luminância carrega a forma inteira — borda, sombra, ruído e relevo
sobrevivem, só a cor anda.

Texto usa uma rampa em degrau, porque a paleta nomeia três papéis e só três:
`>=176 → #ebbf90` (texto), `>=112 → #a87f68` (dim), abaixo → `#6b4d40` (placeholder).

---

## ⚠️ O mockup em `ui-login/` é o pacote ANTIGO

`ui-login/reference/login-module.png` na raiz do workspace **não é a referência válida**. O
commit `b0b9548` a rejeita explicitamente:

> O pacote `D:\backlands\ui-login` usado nos 2 commits anteriores estava desatualizado: foi
> escrito antes de alguém ler o código real do cliente. A janela real tem token 2FA, seleção
> de servidor, servidor customizado, login com Google e botão de gravações — nada disso
> existe no mock que o pacote antigo assumia.

O pacote correto é `Login Pixel Art Retro\ui-login`, com `AUDITORIA-CLIENTE.md`, e a
abordagem dele é a que esta branch segue: reskinar os sprites genéricos compartilhados.

**Esse pacote não está nesta máquina.** `Login Pixel Art Retro.zip` na raiz do workspace tem
22 bytes — é um ZIP vazio (só o end-of-central-directory). E o `AUDITORIA-CLIENTE.md` nunca
foi commitado em nenhum dos repositórios.

Consequência prática: **não dá para comparar contra mockup**. Reconstruir a tela de login a
partir de `ui-login/reference/login-module.png` desfaria uma decisão registrada e apagaria
funcionalidades. Enquanto o pacote certo não aparecer, a referência utilizável é a coerência
interna — que é o critério que esta sessão usou.

---

## Próximos passos

1. **Recuperar o pacote `Login Pixel Art Retro`** (com `AUDITORIA-CLIENTE.md`) e commitá-lo,
   ou pelo menos o `.md`, para o próximo agente não tropeçar no mock velho de novo.
2. **Restam `font: cipsoftFont` em slots de action bar** — a letra da tecla num slot de
   32px, onde 16px não cabe. Os botões de janela já migraram.
3. **O que sobra do HUD em Verdana são números sobre slot de 32px** — os rótulos F1..F12 da
   action bar, e Soul/Cap ("10000" mede 53px num slot de 34 centralizado nele, e imprime por
   cima dos slots vizinhos). O resto do topo já migrou: barras de vida e mana, contador de
   level, painel de status do canto, abas do chat.

   > A leitura anterior de que o HUD "não cabia" estava errada, e por um motivo mensurável:
   > comparava cada rótulo com a largura declarada dele, não com o contêiner. O número de vida
   > tem 78px próprios mas 642 de contêiner. O obstáculo real era outro: 	opbar.lua chamava
   > setFont("Verdana Bold-11px") em runtime, então o que o .otui declarava nunca valia.
4. **3 nomes de outfit** ainda quebram (`Necromancer`, `Entrepreneur`, `Orcsoberfest`).
   Caberiam num tile de 134px, mas dois deles mais a coluna de preview não cabem na janela.
5. **24 sprites cinza** ainda referenciados, todos ícones (`icon-questionmark`, `copy-all`,
   `paste`, `hide-pin`, `item-blessed`). A rampa ali custaria legibilidade sem ganhar nada.
6. **8 valores `color: white`** ficaram de fora porque ali `color` não é texto: barra de
   progresso (preenchimento), `UIItem` (tint do sprite) e três `UIWidget` onde o papel não
   dá para ler pelo tipo.

## Armadilhas já pagas — não repita

- **`text-offset` negativo para fingir alinhamento à esquerda.** Empurra texto centralizado
  para fora do widget e quebra sozinho na próxima mudança de largura. Aconteceu no cabeçalho
  do Highscores e no da character list. Use `text-align: left`.
- **Ancorar um par rótulo/valor cruzado.** `A.right: B.left` com `B.top: A.top` é ciclo para
  o resolvedor de âncoras mesmo em eixos diferentes: ele loga
  `recursively anchored to itself` e **descarta** a âncora. Ancore o valor num terceiro
  widget com id próprio.
- **`image-offset` ao estreitar um `UIButton`.** Se a seta cair fora do widget, o cálculo do
  texto se desloca e o rótulo vai parar fora da janela. Reduza junto (`largura - 7 - 4`).
- **`WriteAllLines` do .NET junta com `Environment.NewLine`**, que no Windows é CRLF. Os
  `.otui` deste repo são LF: uma passagem em lote reescreveu 108 arquivos inteiros e afogou
  450 linhas reais em 44k de ruído. Use `WriteAllText` com `\n` explícito.
- **`Set-Content -Encoding utf8` no PowerShell 5.1 grava BOM.**
- **`Get-Content` devolve string, não array, quando o arquivo tem uma linha só** — indexar
  entrega um `Char`. Use `@(Get-Content ...)`.
- **Estilos duplicados.** `SelectionButton` está declarado igual em `40-hirelingwindow`,
  `40-outfitwindow` e `40-renownwindow`; os estilos carregam em ordem alfabética e o último
  vence. Editar o arquivo "certo" pode não mudar nada na tela.
- **Automação de captura**: minimizar/restaurar a janela para forçar foco às vezes abre o
  menu Iniciar por cima e provoca `Render error: 1286` nessa GPU antiga. Artefato da
  automação, não do cliente.

## Como validar

Nesta máquina **não há Docker**. O stack sobe nativo:

```powershell
.\tools\run-local.ps1 -NoClient    # MariaDB portátil + server\build\tfs.exe
.\tools\uiplay.ps1                 # cliente, login e entrada no mundo
```

MariaDB portátil em `%USERPROFILE%\mariadb`; banco `forgottenserver`, usuário
`forgottenserver` sem senha (`mysql_native_password`).

Conta de teste: **`god` / `god`**, personagem **Backlands God** (level 200, conta type 5 —
abre qualquer janela do jogo). A conta `1` / `1` existe mas só tem o "Account Manager", que
não carrega: `iologindata.cpp` força Town ID 1, que não existe no mapa.
