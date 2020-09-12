import os
from datetime import datetime, date, timedelta
from lxml import html 
import requests 
import re
from glob import glob
 
def find_last_date(output_folder):
    filescsv = glob(output_folder + '/*.csv')
    fileszip = glob(output_folder + '/*.zip')
    filesxz = glob(output_folder + '/*.xz')
    filesbz2 = glob(output_folder + '/*.bz2')
    files = filescsv + fileszip + filesxz + filesbz2
    date_max = date(year=2020, month=1, day=1)
    for f in files:
        g = re.match(r'.*(\d\d\d\d_\d\d_\d\d).*', os.path.basename(f))
        if g:
            data = datetime.strptime(g.groups()[0], "%Y_%m_%d").date()
            date_max = max(data, date_max)
    return date_max

def check_new_update_date(index_page_address, data):
    page = requests.get(index_page_address, verify=False, timeout=10)
    tree = html.fromstring(page.content)
    datas = tree.xpath('//span[@class="automatic-local-datetime"]')
    for d in datas:
        dt = datetime.strptime(d.attrib['data-datetime'], r"%Y-%m-%dT%H:%M:%S%z").date()
        if dt > data:
            return dt
    return False

def get_file(download_address, output_file):
    r = requests.get(download_address, verify=False, allow_redirects=True, timeout=10)
    open(output_file, 'wb').write(r.content)

def get_resource_names(index_page_address):
    page = requests.get(index_page_address, verify=False, timeout=10)
    tree = html.fromstring(page.content)
    res = tree.xpath('//a[@class="heading"]')
    resources = []
    for r in res:
        g = re.match(r'.*dados-(.*)\.csv.*', r.text.strip('\n'))
        if g:
            resources.append(g.groups()[0])
    return resources

if __name__ == '__main__':
    index_page_address = 'https://opendatasus.saude.gov.br/dataset/casos-nacionais'
    download_address = "https://s3-sa-east-1.amazonaws.com/ckan.saude.gov.br/dados-{estado}.csv"
    output_folder = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../dados/eSUS-VE')
    gitUpdate = True

    #estados = ["ac", "al", "am", "ap", "ba", "ce", "df", "es", "go",
    #        "ma", "mg", "ms", "mt", "pa", "pb", "pe", "pi", "pr", "rj", "rn",
    #        "ro", "rr", "rs", "sc", "se", "sp", "to"]
    res = get_resource_names(index_page_address)

    last_date = find_last_date(output_folder)
    data = check_new_update_date(index_page_address, last_date)
    if data:
        print("Downloading new esus-ve database...")
        new_files = []
        for estado in res:
            output_file = output_folder + '/esus-ve_{estado}-{data}.csv'.format(estado=estado,
                    data=data.strftime("%Y_%m_%d"))
            get_file(download_address.format(estado=estado), output_file)
            os.system("bzip2 " + output_file)
            new_files.append(output_file + '.bz2')
        # add to git and let the other robots work
        if gitUpdate:
            os.system("cd {folder} && git pull --ff-only".format(
                folder=output_folder))
            os.system('''cd {folder} &&
                   git add {outfiles} &&
                   git commit -m "[auto] bases esus-ve de hoje" &&
                   git push'''.format(folder=output_folder,
                                    outfiles=' '.join(new_files)))

