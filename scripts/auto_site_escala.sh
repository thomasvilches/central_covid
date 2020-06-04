#!/bin/bash

# script assume que é rodado dentro do meta-repo, numa pasta abaixo da raiz
# ../nowcasting: repo nowcasting
# ../site: repo site

usage(){
    echo -e "
USO: $0 [escala] [estado] [trim] {geocodes}

  escala: municipio | micro | meso | drs
  estado: sigla do estado (não misturar geocodes de estados diferentes)
  trim: dias de trim do nowcasting, geralmente 2-5
  geocodes: lista de geocodes, ou ids de DRSs
"
}

# cuidado: argumento precisa ter aspas *simples* pra não ser expandido
# data deve vir no formato YYYY_MM_DD no nome do arquivo
get_latest(){
    pattern=`basename "$1"`
    lspat=`echo $1 | sed 's/{data}/*/'`
    greppat=`echo $pattern | sed 's/*/.*/g; s/{data}/.*/'`
    sedpat=`echo $pattern | sed 's/*/.*/g; s/{data}/\\\\([0-9][0-9][0-9][0-9]_[0-9][0-9]_[0-9][0-9]\\\\)/'`
    ls `eval echo $lspat` | grep "$greppat" | sed  's/^.*'$sedpat'/\1/' | sort -gr | head -n 1
}

if [ ${#@} -lt 4 ]; then
    usage
    exit 1
fi

SCRIPTROOT=$PWD

estado="SP"

escala=$1
# TODO: discutir tamanho do trim (atual: 2 pra municipio, 5 pra DRS?)
estado=$2
trim=$3
shift 3
geocodes=( "$@" )

# cada estado pode ter uma base diferente
# ATENÇÃO: não misturar municípios de estados diferentes!
if [ $estado == "SP" ]; then
    datafolder="../dados/estado_${estado}/SRAG_hospitalizados/dados"
else
    datafolder="../dados/SIVEP-Gripe"
fi
Rfolder="../nowcasting"
outfolder="../dados_processados/nowcasting"
# convertendo caminhos relativos em absolutos
# realpath é mais profissa, mas não é garantido ter em todo lugar
if [ ${datafolder:0:1} = '/' ]; then
    absdatafolder=$datafolder
else
    absdatafolder="$PWD/$datafolder"
fi
if [ ${outfolder:0:1} = '/' ]; then
    absoutfolder=$outfolder
else
    absoutfolder="$PWD/$outfolder"
fi


# atualiza repo onde dados estão?
UPDATE_GIT_DATA_REPO=TRUE

if [ $escala == "municipio" ]; then
    folder="municipios"
elif [ $escala == "drs" ]; then
    folder="DRS"
elif [ $escala == "meso" ]; then
    folder="mesorregioes"
elif [ $escala == "micro" ]; then
    folder="microrregioes"
else
    usage
    exit 1
fi

# associative array of names
# requires iconv
declare -A nomes
for geocode in ${geocodes[@]}; do
    if [ $escala == "municipio" ]; then
        nomes[$geocode]=`awk -F, '/'"$geocode"'/ {gsub(/"/, "", $13); print $13}' ../nowcasting/dados/geocode_ibge.csv`
    elif [ $escala == "drs" ]; then
        nomes[$geocode]=`awk -F, '{ if($2 == '"$geocode"') {gsub(/"/, "", $5); print $5}}' ../nowcasting/dados/DRS_SP.csv | head -n1`
    elif [ $escala == "meso" ]; then
        nomes[$geocode]=`awk -F, '{if($5 == '"$geocode"') {gsub(/ /, "_"); gsub(/"/, ""); print $6; exit}}' ../nowcasting/dados/geocode_ibge.csv | iconv -f utf8 -t ascii//TRANSLIT -`
    elif [ $escala == "micro" ]; then
        nomes[$geocode]=`awk -F, '{if($3 == '"$geocode"') {gsub(/ /, "_"); gsub(/"/, ""); print $4; exit}}' ../nowcasting/dados/geocode_ibge.csv | iconv -f utf8 -t ascii//TRANSLIT -`
    fi
done

# pull do meta-repo: *DANGER HERE*
# este pull é pra você poder atualizar o meta-repo depois - se tiver base nova
# o commit do submodulo dele estará *desatualizado*
git pull --recurse-submodules --ff-only
pushd $absdatafolder
# AQUI pegamos alterações novas, sem detached HEAD no submodule
git checkout master && git pull --ff-only
popd

RUNFILE="nowcasting_site_${folder}_${estado}.run"
last_input_csv=`get_latest '$absdatafolder/SRAGH*_{data}.csv'`
last_input_zip=`get_latest '$absdatafolder/SRAGH*_{data}.zip'`
last_input=`echo -e "$last_input_csv\n$last_input_zip" | sort | tail -n1`
last_output=`get_latest '../site/dados/'${folder}'/'${estado}'/'${nomes[${geocodes[0]}]}'/tabelas_nowcasting_para_grafico/nowcasting_acumulado_covid_{data}.csv'`

if [[ -f $RUNFILE || ! $last_output < $last_input ]]; then
    # rodando ou atualizado
    exit
fi

today_=$last_input
todaydash=`echo $today_ | sed 's/_/-/g'`

echo "Nova atualização nowcasting ${today_} ${escala} ${estado} ${geocodes[@]}"

# esta é arcana...
output_files="nowcasting_{acumulado,diario}_{,obitos_}{covid,srag}_${today_}.csv
tempo_duplicacao_{,obitos_}{covid,srag}_${today_}.csv
r_efetivo_{covid,srag}_${today_}.csv"
web_output_files="last.update.txt
data_{forecast_exp,tempo_dupli}_{,obitos_}{covid,srag}.csv
data_Re_{covid,srag}.csv
plot_nowcast_{,cum_}{,ob_}{covid,srag}.html
plot_nowcast_{,cum_}{,ob_}{covid,srag}{,.ex,.lg,.md,.sm}.svg
plot_tempo_dupl_{,ob_}{covid,srag}.html
plot_tempo_dupl_{,ob_}{covid,srag}{,.ex,.lg,.md,.sm}.svg
plot_estimate_R0_{covid,srag}.html
plot_estimate_R0_{covid,srag}{,.ex,.lg,.md,.sm}.svg"
# eval expande todos wildcards nas variáveis
output_files=`eval echo $output_files`
web_output_files=`eval echo $web_output_files`

touch $RUNFILE

pushd $Rfolder
for geocode in ${geocodes[@]}; do
    ## nowcasting
    # ATENÇÃO: se UPDATE_GIT_DATA_REPO for FALSE dados *não são* salvos,
    # permanecem como cópia local, suja. Se deseja limpar, pode rodar
    # depois:
    # cd $absoutfolder/outputs; git clean -f
    # que *apaga* todos arquivos untracked (DANGER)
    Rscript update_nowcasting.R --dir $absdatafolder --escala $escala --sigla $estado --geocode $geocode --dataBase $today_ --outputDir $absoutfolder --trim $trim --updateGit $UPDATE_GIT_DATA_REPO

    ## mandando pro site
    path="${folder}/${estado}/${nomes[$geocode]}"

    # atualiza repo site
    # isto é feito a cada passo do loop - mais seguro?
    pushd $SCRIPTROOT/../site/_src
    git pull --ff-only

    # cria destino se não existe
    if [ ! -d ../dados/$path/tabelas_nowcasting_para_grafico/ ]; then
        mkdir --parents ../dados/$path/tabelas_nowcasting_para_grafico
    fi

    pushd $absoutfolder/$path/tabelas_nowcasting_para_grafico/
    cp $output_files $SCRIPTROOT/../site/dados/$path/tabelas_nowcasting_para_grafico/
    popd

    Rscript update_plots_nowcasting.R --escala $escala --sigla $estado --geocode $geocode --dataBase $today_
    pushd ../dados/$path/tabelas_nowcasting_para_grafico/
    git add $output_files
    popd
    pushd ../web/$path
    git add $web_output_files
    popd
    git commit -m ":robot: novas tabelas e plots ${escala} ${estado}-${nomes[$geocode]} ${today_}" &&
    git push
    popd
done
popd

### Isto só é necessário se o outfolder for dentro de um submodulo
#if [ $UPDATE_GIT_DATA_REPO == "TRUE" ]; then
#    # update meta-repo pro novo commit
#    git commit ../dados/estado_$estado -m ":robot: Atualizando commit estado ${estado}" &&
#    git push
#fi

rm $RUNFILE
