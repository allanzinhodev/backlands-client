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

Quatro varreduras, cada uma alcançando o que a anterior não via, e as quatro passam limpas:

| Ferramenta | Alcance | Como chega lá |
|---|---|---|
| `tools/uisweep.ps1` | 47 janelas de módulo | abre pela função pública do módulo |
| `tools/uiminis.ps1` | 47 mini-janelas | pergunta ao cliente quais existem nos painéis |
| `tools/uideep.ps1` | 26 janelas, painel a painel | todas as abas, não só a visível |
| `tools/uistyles.lua` | 50 estilos de janela | instancia pelo nome, sem passar pelo módulo |
| `tools/uicontrast.ps1` | 20 telas, pixel a pixel | mede se o texto **aparece**, não só onde cai |

A varredura estática (`tools/otui-textfit.ps1`) reporta **0 estouros**. `tools/otui-lint.js`
passa nos 473 arquivos OTML do cliente.

> **Cada vez que o alcance da varredura cresceu, apareceu defeito.** Auditar só a aba visível
> escondia 49 (o Cyclopedia tem nove abas, a de Opções quinze páginas, o Helper seis, o Prey
> três estados por slot). Abrir só o que tem função pública de abrir escondia mais 15 — o
> cliente declara 84 janelas e metade só abre com dado que o servidor manda (a Store precisa
> do catálogo, o Market das ofertas, o Wheel da árvore de perícia). Instanciar o estilo pelo
> nome passa por cima disso: o layout é o mesmo, só o conteúdo fica vazio, e é o layout que a
> fonte nova quebra.

`tools/fontcensus.lua` pergunta `getFont()` nos 20446 widgets do cliente com tudo aberto:
**1725 widgets com texto em silkscreen-16**, 14 nas duas exceções documentadas (F1–F12 e
Cap/Soul nos slots de 32px) e 45 no terminal de dev, que fica de fora de propósito.

A única janela que não abre é `npctrade`: o Lua dela quer dados de troca vindos do servidor,
não é defeito de UI.

> **As duas "exceções" não são resíduo — são fontes pixel menores.** `verdana-8px-rounded`
> (F1–F12), `verdana-cap-bold` (Cap/Soul) e `verdana-11px-rounded` (nomes no mapa) têm
> **dois níveis de alfa, 0 e 255**: são bitmap sem antialiasing, tão pixel quanto a
> silkscreen — que, ironicamente, é a única das cinco com alfa intermediário. O nome
> "verdana" engana; o que elas são é uma face menor, escolhida onde 16px de altura não cabem
> (slot de 32px) ou onde 16px de largura empurrariam o texto sobre o vizinho ("10000" mede
> 53px num slot de 34). Não há nada a migrar ali.

> **A medição errada esconde a metade do trabalho.** Três vezes nesta migração uma
> ferramenta deu "tudo limpo" enquanto a tela estava errada, sempre pelo mesmo motivo: ela
> perguntava ao *disco* ou ao *fonte* uma coisa que só o **cliente rodando** sabe.
> `palettecheck` conta 836 sprites cinzas varrendo pastas, mas a maioria é arte de conteúdo
> ou morta; `regrade-batch` decide por referência literal no fonte e não vê
> `setImageSource("/images/topbuttons/%s.png", v)`; `fontaudit` mede a largura do texto que
> existe *agora* e por isso não viu que a mensagem de chat estava em Verdana. As três
> respostas certas — `imgsources.lua`, `greyshot.js`, `fontcensus.lua` — perguntam ao
> cliente. Ao retomar, prefira sempre a ferramenta que pergunta ao cliente.

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

| Chrome que a varredura por pasta não via | 312 sprites | `imgsources.lua` pergunta ao cliente o que está preso a um widget; `regrade-live.js` age só nisso |
| Zebra de lista em cinza | `#414141`/`#484848`, 49 usos em 19 arquivos | o par que `0-vars.otui` já definia: `#281b17` / `#2c1e19` |
| Placa escura com tinta escura | `/images/ui/buttons-blue`, 18 widgets | `color: #ebbf90` junto da image-source; o rótulo tinha sumido por completo |
| Chat, mensagem de tela e barra de vida em Verdana | `ConsoleLabel`, `TextMessageLabel`, healthinfo, boss health | achados só pelo censo de fonte; larguras de quebra crescidas junto |

Depois disso o que ainda está cinza é **arte de conteúdo ou informação**: 51 sprites que o
`regrade-live` recusa de propósito (a pasta inteira de `combatmodes` e de `states`, onde
`whitedovemode` e `redfistmode` são o mesmo desenho em cores que significam coisas
diferentes; `button-blessings-grey-idle` ao lado da variante colorida; o seletor de cores),
e o chão de pedra do mapa, que é sprite de jogo.

**Cinza não era o único jeito de estar fora da paleta.** `regrade-live` só troca cinza
neutro, então nada saturado jamais entrava — e sobraram dez sprites de chrome gritando azul
ou verde: o botão da Store, o `Boost Kills` do Task Hunt, o `large_blue_button`, o
`buy-potions-button`, as cartas do prey, a faixa de XP Boost, o `getCoins`. Uma varredura por
**matiz** nos sprites vivos acha isso, e `regrade.js --force` resolve (passa a rampa em todo
pixel, não só no cinza). Cuidado com a métrica: matiz só faz sentido em pixel claro e
saturado — nos escuros ele oscila, e a primeira tentativa acusou `panel_flat` a 94% "fora"
logo depois de eu tê-lo recolorizado. Dos 30 restantes, 29 são conteúdo ou informação: barra
de vida verde, barra de mana azul, ícones de magia e de imbuement, o mostrador dia/noite do
minimapa, as chaves de cor.

**O texto sobre o mapa não é resíduo da skin antiga.** Nomes de criatura
(`creature.cpp:103`), números de dano (`animatedtext.cpp:32`) e fala
(`statictext.cpp:35`) usam `verdana-11px-rounded`, e essa face tem **dois níveis de alfa
(0 e 255)** — é bitmap sem antialiasing, tão pixel quanto a silkscreen, só mais estreita.
Trocá-la por silkscreen-16 exigiria recompilar e deixaria um nome de 13 letras com 130px
sobre um tile de 32. Fica como está, de propósito.

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
.\tools\uisweep.ps1 -OutDir shots           # as 36 janelas de módulo, uma a uma
.\tools\uiminis.ps1                         # as 47 mini-janelas da sidebar
.\tools\uideep.ps1                          # 26 janelas, painel a painel
# e as que so abrem com dado de servidor, instanciadas pelo nome do estilo:
.\tools\uidrive.ps1 -Action lua -File tools\uistyles.lua -LuaArg "cria BossDifficultyWindow ..."
.\tools\uidrive.ps1 -Action lua -File tools\uistyles.lua -LuaArg "audita"
```

`uistyles` vai em duas chamadas de propósito: `createWidget` só **agenda** o layout, e medir
no mesmo quadro pega os filhos em posição provisória — isso produziu uma dúzia de
`ESCAPA-Y buttonOk` que sumiam sozinhos no quadro seguinte. Vale a mesma regra do `uipanels`.

`uideep` junta as duas maneiras de trocar de painel. Onde o módulo só mostra e esconde,
`uipanels.lua` **descobre os grupos sozinho**: irmãos com o mesmo retângulo, dos quais no
máximo um está visível (painel fora do retângulo da janela não entra — é grade rolada para
fora da vista). Onde o módulo faz mais do que isso, o script chama a função dele: o
`game_helper` **redimensiona a janela por aba** (380x275 no tools, 430x550 no cavebot), e
auditar ali sem passar pelo módulo mede tudo no tamanho errado e ainda deixa dois painéis
visíveis ao mesmo tempo, gerando colisões que não existem.

`uisweep` acha a janela recém-aberta pelo último filho visível da raiz. Mini-janela não
aparece ali — ancora dentro do `gameRootPanel` —, e são justamente as que mais sofrem com a
fonte nova, porque dividem 178px de sidebar. Daí o `uiminis.ps1`, que **pergunta ao cliente**
quais existem em vez de manter uma lista de `toggle()` à mão (a lista alcançava 13 de 47).
Ele revela cada janela fechada, mede e devolve ao estado anterior — em chamadas separadas ao
driver, porque `setVisible` só agenda o layout e medir no mesmo quadro lê o rect velho.

O mod fica em `tools/uidriver/` e o `uidrive.ps1` copia para `client/mods/zz_uidriver/` ao
subir. O cliente **não** versiona essa pasta. Screenshot sai por `g_app.doScreenshot`, que
grava o framebuffer sem borda de janela — pixel (0,0) é o canto do conteúdo, e a imagem entra
direto no `probe.js`.

### A auditoria em runtime (`UID.audit`)

É a metade que a varredura estática não faz. Reporta quatro coisas:

- `ESTOURA` — texto pintado fora do próprio widget, e quanto é cortado de cada lado
- `COLIDE` — dois textos pintados um sobre o outro
- `ESCAPA` / `ESCAPA-Y` — texto fora da área útil da janela
- `ALTURA` — texto quebrado mais alto que a caixa
- `SAI-RECT` — filho cujo retângulo sai da área útil
- `TAPADO` — texto enterrado sob um painel opaco desenhado depois

> **A geometria não prova que o texto aparece.** Duas vezes nesta migração um texto sumiu por
> inteiro sem violar nenhuma das seis regras acima: o `Sell All` do npctrade, quando o botão
> ganhou a placa escura e manteve a tinta escura que `Button` pinta para a placa dourada; e o
> `Anonymous` do Market, desenhado 4px abaixo do painel que o contém — não cortava, não
> colidia com texto, não saía da *janela*. Nas duas a única prova foi uma captura ampliada,
> olhada por acaso. Hoje é `uicontrast.ps1` quem prova: caixa de texto legível tem duas
> populações de luminância (glifo e fundo) separadas; se tudo cabe numa faixa estreita, não há
> glifo visível ali.

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
node tools\pixelui\greyshot.js shots                       # quanto de cada TELA ainda é cinza
.\tools\uidrive.ps1 -Action lua -File tools\imgsources.lua # o que o cliente prende a um widget
node tools\pixelui\regrade-live.js lista.txt client --apply
node tools\pixelui\regrade.js in.png out.png [--force]     # um sprite
node tools\pixelui\palettecheck.js client\data\images\ui   # quanto de cada ARQUIVO é cinza
node tools\pixelui\regrade-batch.js client --apply         # chrome cinza + referenciado
node tools\pixelui\regrade-otui.js client --apply --text   # literais hex em .otui e .lua
```

As duas primeiras linhas são a ordem certa de trabalho: `greyshot` ranqueia as capturas do
`uisweep` pela fração de cinza neutro — que é a assinatura da skin antiga, já que a paleta
fechada não tem nenhum tom neutro — e diz **qual tela** ainda ficou para trás; `imgsources` +
`regrade-live` resolvem essa tela. `palettecheck` e `regrade-batch` continuam úteis, mas
respondem por arquivo e por isso enganam nos dois sentidos.

`--force` no `regrade.js` passa a rampa em **todo** pixel, não só no cinza neutro. É para o
sprite que é inteiro de outra paleta e não tem acento a preservar — foi o caso do botão azul
da Store no meio de uma sidebar marrom. Use com parcimônia: o guarda de acento existe porque
uma passagem anterior apagou o verde do aceitar e o vermelho do recusar em 24 sprites.

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
5. **Rótulo assado em fonte não-pixel — medido e mantido.** Sobrou tipografia rasterizada
   dentro de sprite: os 20 botões de `data/images/common_buttons/` (`Close`, `Apply`,
   `Cancel`…), as abas do Forge, `Categories:`/`Items:`/`Search:` do Cyclopedia
   (`mods/game_cyclopedia/images/ui/names/`), o `Store` da sidebar. A skin permite rótulo
   fixo assado (Lei 1), e **rebaixá-los para silkscreen não cabe**: `Close` mede 51px na
   fonte pixel e o botão tem 43 de largura; `Categories:` mede 112 num sprite de 72x10.
   Fechar essa diferença exige alargar o widget em cada um dos ~60 pontos de uso, não
   redesenhar o sprite. Não vale o risco de layout pelo ganho.
6. **8 valores `color: white`** ficaram de fora porque ali `color` não é texto: barra de
   progresso (preenchimento), `UIItem` (tint do sprite) e três `UIWidget` onde o papel não
   dá para ler pelo tipo.
7. **`#dfdfdf88` é a cor de `$disabled`** em ~89 lugares (`Label`, `CheckBox`, `ComboBox`,
   `Button`). É cinza translúcido, não resíduo de skin: funciona, mas a paleta tem
   `$var-text-color-disabled` para o mesmo papel. Trocar é seguro e uniformiza; ainda não
   foi feito.

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
- **`setVisible(true)` só agenda o layout.** Medir no mesmo quadro lê o rect antigo. O
  impact analyser relatou seis colisões que sumiram sozinhas no quadro seguinte, e a janela
  de skills uma entre "Bonus" e "Food" que nunca existiu. Revele numa chamada ao driver,
  meça em outra, e descarte o achado que não sobrevive a uma segunda medição.
- **Placa clara pede tinta escura, e vice-versa.** `Button` pinta o rótulo em `#150e0c`,
  pensado para a placa dourada. Os 18 widgets que trocam a image-source para
  `/images/ui/buttons-blue` (fundo `#150e0c`) ficavam com rótulo invisível — não cortado,
  não deslocado: **ausente**, e nenhuma auditoria de geometria ou de fonte pega isso. Ao
  trocar a placa de um botão, declare a cor do texto junto.
- **Crescer um painel não move o que não está ancorado nele.** `NpcWindowContents` usa
  `margin-top` fixo a partir do topo da janela, não `headPanel.bottom`. Crescer o cabeçalho
  23px pôs a lista de itens por cima do botão que eu tinha acabado de mover para lá.
- **`sed "Na\\${ind}texto"` não indenta.** O `\\$` vira `$` literal e a linha entra na coluna
  0, quebrando a indentação de 2 do OTML em 18 arquivos de uma vez. Para inserir linha
  indentada, use `awk` lendo a indentação da linha anterior.
- **O placeholder não herda a fonte do widget.** `uitextedit.cpp:63` faz
  `m_placeholderFont = g_fonts.getDefaultFont()`. Nenhum censo de `getFont()` pega isso, e as
  75 caixas de busca continuaram em Verdana muito depois de todo o resto migrar. Existe
  `placeholder-font` no OTML — declare junto do `placeholder`.
- **Rótulo com âncora esquerda E direita ignora `text-auto-resize`.** A caixa fica do
  tamanho do vão entre as duas âncoras e o texto é cortado nos dois lados. Foi o
  "Raise limit from" do Forge, ancorado nas duas bordas de um botão de 128px.
- **Dois widgets com o mesmo `id`.** `game_report` e `game_transfer` declaravam ambos
  `id: mainWindow`; `UID.find` e `getChildById` devolvem o primeiro, então a segunda janela
  não podia ser auditada nem referenciada. Janela sem `id` (só o automático `widget21125`,
  que muda a cada carga) tem o mesmo problema.
- **Coluna alinhada por `margin-right` afinado a mão.** A página de screenshot alinhava nove
  checkboxes fazendo cada uma ancorar à direita com uma margem própria, para que os rótulos
  começassem todos no mesmo x **naquela** fonte. Com outra fonte cada um cresce para a
  esquerda em ritmo diferente. Ancore a coluna à esquerda num x fixo.
- **`setColor` em runtime não aparece em varredura de `.otui`.** A maior parte do vocabulário
  de cor da skin antiga estava em `.lua`, aplicado depois que a tela carrega: 162 chamadas
  (`#c0c0c0` para linha normal, `#f4f4f4` para selecionada, `#707070` para inativa). Nenhum
  lint, nenhum censo e nenhuma auditoria de geometria alcança isso — só um `grep` por
  `setColor` no Lua.
- **O tooltip inverte a hierarquia.** Ele tem fundo dourado (`#c68f66`) e tinta escura, então
  ali claro é fundo e escuro é texto — o contrário de todo painel do jogo. Uma troca cega de
  `#c0c0c0` para a paleta pintou a mensagem da janela de morte de `#231815` sobre um painel
  `#231815`. Ao mexer em cor de texto no Lua, verifique se o destino é `setTooltip` ou
  `setColoredText` num rótulo de janela.
- **Estilo base que declara `font` mas não `color`** herda o branco do `UIWidget`. `CheckBox`,
  `CheckBoxCircle` e `PopupMenuCheckBoxCircle` estavam assim, e o `$disabled` das três só
  trocava o cursor — caixa desabilitada ficava idêntica à habilitada.
- **Rótulo sem `size:` e sem `text-auto-resize`** fica com a largura que o estilo base deu, e
  o estilo base foi medido na fonte antiga. Dez rótulos do Helper estavam assim. Auto-resize
  é a correção certa quando há espaço à direita — mas confira o vizinho depois, porque dois
  pares que antes cabiam passaram a se tocar.

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
