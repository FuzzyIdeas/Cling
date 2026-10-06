//
//  CodeExtensions.swift
//  Cling
//
//  Every extension GitHub's Linguist lists for a language (code, markup, data or prose), from
//  github-linguist/linguist's lib/linguist/languages.yml. macOS knows few of them as text, and gives some to apps that
//  claim them for something else (.ts as a video, .stl as a 3D model), so the file server reads files with these to
//  see whether they're text.
//

extension WebViewKind {
    static let codeExtensions = Set(
        """
        1 1in 1m 1x 2 2da 3 3in 3m 3p 3pm 3qt 3x 4 4dform 4dm 4dproject 4gl 4th 5 6 6pl 6pm 7 8 8xp 9 _coffee _js _ls
        a51 abap abnf action ada adb adml admx ado adoc adp ads afm agc agda ah1 ah2 ahk ahkl aidl aj ak al aleo alg als
        ampl angelscript anim ant apacheconf apex apib apl app applescript arc arpa arr as asax asc asciidoc ascx asd
        asddls ash ashx asl asm asmx asn asn1 asp aspx asset astro asy au3 aug auk aux avdl avsc aw awk axaml axd axi
        axml axs b bal baml bas bash bat bats bb bbappend bbclass bbcode bbx bdf bdy be befunge bend bf bi bib bibtex
        bicep bicepparam bison blade blp bmx bones boo boot bpl bqn brd bro brs bru bs bsl bst bsv builder builds bzl c
        c++ c++-objdump c++objdump c-objdump c3 cabal caddyfile cairo cake capnp carbon cats cbl cbx cc ccp ccproj ccxml
        cdc cdf cds ceylon cfc cfg cfm cfml cgi cginc ch chem chpl chs cil circom cirru cj cjs cjsx ck cl cl2 clar click
        clixml clj cljc cljs cljscm cljx clp cls clue clw cmake cmd cmp cnc cnf cob cobol cocci code-snippets
        code-workspace coffee com command conll conllu container containerfile cook coq cp cpp cpp-objdump cppm
        cppobjdump cproject cps cpy cql cr crc32 creole cs csc cscfg csd csdef csh cshtml csl cson csproj css csv csx ct
        ctl ctp cts cu cue cuh curry cw cwl cxx cxx-objdump cy cylc cyp cypher d d-objdump d2 dae darcspatch dart das
        dats db2 dcl ddl decls depproj desktop dfm dfy dhall di diff dircolors dita ditamap ditaval djs dlm dm do
        dockerfile dof doh dot dotsettings dpatch dpr druby dsc dsl dsp dsr dtx duby dwl dyalog dyl dylan dzn e eb ebnf
        ebuild ec ecl eclass eclxml ecr ect edc edge edgeql editorconfig edn eh ejs el eliom eliomi elm elv em emacs
        emberscript eml env epj eps epsi eq erb erl es es6 escript esdl ets ex exs eye f f03 f08 f77 f90 f95 factor fan
        fancypack fbs fcgi fea feature filters fir fish flex flf flix flux fnc fnl for forth fp fpp fppi fr frag frg frm
        frt fs fsh fshader fsi fsproj fst fsti fsx fth ftl ftlh fun fut fx fxh fxml fy g g4 gaml gap gawk gbl gbo gbp
        gbr gbs gco gcode gd gdb gdbinit gdnlib gdns gdshader gdshaderinc ged gemspec geo geojson geom gf gi gitconfig
        gitignore gjs gko glade gleam glf glsl glslf glslv gltf glyphs gmi gml gms gmx gn gni gno gnu gnuplot go god
        gohtml golo gotmpl gp gpb gpt gpx gql grace gradle graphql graphqls groovy grt grxml gs gsc gsh gshader gsp gst
        gsx gtkrc gtl gto gtp gtpl gts gv gvy gyp gypi h h++ ha hack haml handlebars har hats hb hbs hc hcl heex hexpat
        hh hhi hic hip hlean hlsl hlsli hocon hoon hpp hqf hql hrl hs hs-boot hsc hta htm html http hujson hurl hx hxml
        hxsl hxx hy hzp i i3 i7x ical ice iced icl icls ics idc idr ig ihlp ijm ijs ik il ily imba iml inc ini ink inl
        ino ins intr io iol ipf ipp ipynb irclog isl ispc iss iuml ivy ixx j j2 jac jade jai jake janet jav java
        javascript jbuilder jcl jelly jflex jinja jinja2 jison jisonlex jl jq js jsb jscad jsfl jsh jslib jsm json
        json-tmlanguage json5 jsonc jsonl jsonld jsonnet jsp jspre jsproj jss jst jsx jte just k kak kdl kicad_mod
        kicad_pcb kicad_sch kicad_sym kicad_wks kid kit kk kml kojo kql krl ks ksh ksy kt ktm kts kv l lagda langium
        lark las lasso lasso8 lasso9 latte launch lbx ld lds lean leex lektorproject leo less lex lfe lgt lhs libsonnet
        lid lidr ligo linq liq liquid lisp litcoffee livecodescript livemd lkml ll lmi lobster logtalk lol lookml lp lpr
        ls lsl lslp lsp ltx lua luau lvclass lvlib lvproj ly m m2 m3 m3u m3u8 m4 ma mak make makefile mako man mao
        markdown marko mask mat mata matah mathematica matlab mawk maxhelp maxpat maxproj mbox mbt mc mcfunction mch
        mcmeta mcr md md2 md4 md5 mdoc mdown mdpolicy mdwn mdx me mediawiki mermaid meta meta4 metal metta mg minid mint
        mir mirah mjml mjs mk mkd mkdn mkdown mkfile mkii mkiv mkvi ml ml4 mli mligo mlir mll mly mm mmd mmk mms mo mod
        mojo monkey monkey2 moo moon mount move mpl mps mq4 mq5 mqh mrc ms msd msg mspec mss mt mtl mtml mts mu mud muf
        mumps muse mustache mxml mxt mysql myt mzn n nanorc nas nasl nasm natvis nawk nb nbp nc ncl ndproj ne nearley
        ned neon network nf nginx nginxconf ni nim nimble nimrod nims ninja nit nix njk njs nl nlogo no nomad nproj nqp
        nr nse nsh nsi nss nu numpy numpyw numsc nuspec nut ny ob2 obj objdump odd odin ol omgrofl ooc opa opal opencl
        opy orc org os osm outjob overpassql owl ox oxh oxo oxygene oz p p4 p6 p6l p6m p8 pac pacscript pact pan parrot
        pas pascal pasm pat patch pb pbi pbt pbtxt pc pcbdoc pck pcss pd pd_lua pddl pde peggy pegjs pep per perl pfa
        pgsql ph php php3 php4 php5 phps phpt phtml pic pig pike pir pkb pkgproj pkl pks pl pl6 plantuml plb plist plot
        pls plsql plt pluginspec plx pm pm6 pml pmod po pod pod6 podsl podspec pogo polar pony por postcss pot pov pp
        pprx pq praat prawn prc prefab prefs prg pri prisma prjpcb pro proj prolog properties props proto prw ps ps1
        ps1xml psc psc1 psd1 psgi psm1 pt pub pubxml pug puml purs pwn pxd pxi py py3 pyde pyi pyp pyt pytb pyw pyx q
        qasm qbs qc qhelp ql qll qmd qml qnt qs r r2 r3 rabl rake raku rakumod raml rascript raw razor rb rbbas rbfrm
        rbi rbmnu rbres rbs rbtbar rbuild rbuistate rbw rbx rbxmx rbxs rchit rd rdf rdoc re reb rebol red reds reek reg
        regex regexp rego rei religo res resi resource rest resx rex rexx rg rhai rhistory rhtml ring riot rkt rktd rktl
        rl rmd rmiss rnh rno rnw robot roc rockspec roff ron ronn rpgle rpy rq rs rsc rsh rss rst rsx rtf ru ruby rviz s
        sage sagews sail sarif sas sass sats sbatch sbt sc scad scala scaml scd sce scenic sch schdoc sci scm sco scpt
        scrbl scss scxml sd sdc sed self service sexp sfd sfproj sfv sh sh-session sha1 sha2 sha224 sha256 sha256sum
        sha3 sha384 sha512 shader shen shproj sieve sig sip sj sjs sl slang sld slim slint sln slnlaunch slnx sls slurm
        sma smali smithy smk sml smt smt2 snakefile snap snip snippet snippets socket sol soy sp sparql spc spec spin
        sps sqf sql sqlrpgle sra srdf srt sru srv srw ss ssjs sss st stan star sthlp stl ston story storyboard sttheme
        sty styl sublime-build sublime-color-scheme sublime-commands sublime-completions sublime-keymap sublime-macro
        sublime-menu sublime-mousemap sublime-project sublime-settings sublime-snippet sublime-syntax sublime-theme
        sublime-workspace sublime_metrics sublime_session surql sv svelte svg svh svx sw swg swift swig syntax t tab tac
        tact tag talon tape target targets tcc tcl tcsh td te tea templ tesc tese tex texi texinfo textgrid textile
        textproto tf tfstate tftpl tfvars thor thrift thy timer tl tla tlv tm tmac tmcommand tmdl tml tmlanguage tmpl
        tmpreferences tmsnippet tmtheme tmux toc tofu toit tolk toml tool topojson tpb tpl tpp tps tres trg trigger ts
        tscn tsp tst tsv tsx ttl tu twig txi txl txt txtpb txx typ uc udf udo ui unity uno upc uplc ur urdf url urs ux v
        vala vapi vark vb vba vbhtml vbproj vbs vcf vcl vcxproj vdf veo verse vert vh vhd vhdl vhf vhi vho vhost vhs vht
        vhw vim vimrc viw vmb vmf volt vrx vs vsh vshader vsixmanifest vssettings vstemplate vtl vto vtt vue vw vxml vy
        w wast wat watchr wdl webapp webidl webmanifest weechatlog wgsl whiley wiki wikitext wisp wit wixproj wl wlk wls
        wlt wlua workbook workflow wren ws wsdl wsf wsgi wxi wxl wxs x x10 x3d x68 xacro xaml xbm xc xdc xht xhtml xi
        xib xlf xliff xm xmi xml xmp xojo_code xojo_menu xojo_report xojo_script xojo_toolbar xojo_window xpl xpm xproc
        xproj xpy xq xql xqm xquery xqy xrl xs xsd xsh xsjs xsjslib xsl xslt xsp-config xspec xtend xul xzap y yacc yaml
        yaml-tmlanguage yang yap yar yara yasnippet yml yrl yul yy yyp z3 zap zcml zed zeek zep zig zil zimpl zmodel
        zmpl zone zpl zs zsh zsh-theme
        """.split(whereSeparator: \.isWhitespace).map(String.init)
    )
}
