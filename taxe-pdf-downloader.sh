#!/bin/bash

BASE_URL="https://panel.taxe.pl"
COOKIE_FILE=`mktemp`


check_system_requirements() {
	for cmd in mktemp curl wkhtmltopdf; do
		out=`whereis $cmd | cut -d ':' -f 2-`
		if [[ -z "$out" ]]; then
			echo "Command '$cmd' not found, use sth like 'apt-get install $cmd'"
			exit
		fi
	done
}


convert_html_to_pdf() {
	html_file="$1"
	pdf_file="$2"
	tmp_file="${html_file}.tmp.html"

	echo "PDF: pdf_file: $pdf_file"
	echo "PDF: html_file: $html_file"
	echo "PDF: tmp_file: $tmp_file"

	cat "$html_file" \
		| sed 's/window.print();//g' \
		| sed "s#\(href\|src\)=\"/#\1=\"${BASE_URL}/#g" \
		>"$tmp_file"

	wkhtmltopdf -O Landscape -s A4 "$tmp_file" "$pdf_file"

	rm -fv "$tmp_file"
}


do_request() {
	out_file="$1"
	path_query="$2"
	shift 2

	echo "CURL: path/query: $path_query" >&2
	echo "CURL: outfile: $out_file" >&2

	curl \
		--silent \
		"${BASE_URL}${path_query}" \
		-H "Origin: ${BASE_URL}" \
		-H 'Accept-Encoding: gzip, deflate' \
		-H 'Accept-Language: pl-PL,pl;q=0.8,en-US;q=0.6,en;q=0.4' \
		-H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8' \
		-H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Ubuntu Chromium/43.0.2357.81 Chrome/43.0.2357.81 Safari/537.36' \
		-H 'Content-Type: application/x-www-form-urlencoded' \
		-H "Referer: ${BASE_URL}/" \
		--cookie "$COOKIE_FILE" \
		--cookie-jar "$COOKIE_FILE" \
		--compressed \
		--location \
		--output "$out_file" \
		$@

	if test -e "$out_file"; then
		echo "OK, file exists ($out_file)" >&2
	else
		echo "FAILED, file does not exists: $out_file" >&2
		exit
	fi
}


do_post() {
	out_file="$1"
	path_query="$2"
	post_data="$3"

	do_request "$out_file" "$path_query" --data "$post_data"
}


do_get_to_pdf() {
	out_pdf="$1"
	path_query="$2"

	out_html="${out_pdf}.html"

	echo "GET: out_html: $out_html" >&2
	echo "GET: out_pdf: $out_pdf" >&2

	do_request "$out_html" "$path_query"
	convert_html_to_pdf "$out_html" "$out_pdf"
	rm -f "$out_html"
}


do_post_to_pdf() {
	out_pdf="$1"
	path_query="$2"
	post_data="$3"

	out_html="${out_pdf}.html"

	do_post "$out_html" "$path_query" "$post_data"
	convert_html_to_pdf "$out_html" "$out_pdf"
	rm -f "$out_html"
}


do_login() {
	read -p "Login/email: " email
	read -p "Haslo: " -s password

	do_request /dev/null "/"

	post_data="email=${email}&haslo=${password}&fro=&zaloguj=Zaloguj+si%C4%99+%C2%BB"
	tmp_login_page=`mktemp`
	do_post "$tmp_login_page" "/logowanie/" "$post_data"

	grep -q 'Nowy dokument sprzeda' "$tmp_login_page";
	res=$?

	rm -f "$tmp_login_page"
	if [[ $res == 0 ]]; then
		echo "Logowanie ok..." >&2
	else
		echo "Logowanie niepoprawne..." >&2
		exit
	fi
}


do_logout() {
	do_request "/dev/null" "/logowanie/wyloguj/"
	rm -fv "$COOKIE_FILE"
}


show_usage_and_exit() {
	echo "Usage: `basename $1` <YYYY-mm>" >&2
	echo "Will ask for username/password for taxe.pl service." >&2
	exit
}


YEAR_MONTH="2001-01"
FIRST_DAY="2001-01-01"
LAST_DAY="2001-01-31"

YEAR_MONTH="$1"
YEAR=`echo "${YEAR_MONTH}" | cut -d '-' -f 1`
FIRST_DAY=`date -d "${YEAR_MONTH}-01" "+%Y-%m-%d" 2>/dev/null`
if [[ $? != 0 ]]; then
	show_usage_and_exit "$0"
fi
LAST_DAY=`date -d "${FIRST_DAY} + 1 month - 1 day" "+%Y-%m-%d" 2>/dev/null`

echo "Month: $YEAR_MONTH ($FIRST_DAY - $LAST_DAY)"


check_system_requirements
do_login

tmp_raporty_list=`mktemp`
dates_data="dataOd=${FIRST_DAY}&dataDo=${LAST_DAY}"

do_request "${tmp_raporty_list}" "/raporty/wszystkie/?tab=all"
for name in "PIT-5L" "VAT-7" "ZUS"; do
	pdf_url=`cat ${tmp_raporty_list} | tr -d '\n' | sed 's/<h3/\n&/g' | sed -n "s#^.*\<${name}\>.*\<za:.*\<${YEAR_MONTH}\>.*\(/raporty/pdf/[0-9]*\).*\\$#\1#p"`
	if [[ -z "${pdf_url}" ]]; then
		echo "FAILED: cannot find '${name}' id!" >&2
		exit
	fi
	do_request "$YEAR_MONTH taxe - Raport ${name}.pdf" "${pdf_url}"
done

do_post "/dev/null" "/rejestryVAT/" "${dates_data}"
do_request "${tmp_raporty_list}" "/rejestryVAT/"
for name in "Sprzedaz" "Pozostale-zakupy" "Srodki-trwale"; do
	pdf_url=`cat "${tmp_raporty_list}" | tr -d '\n' | sed -n "s#^.*javascript:zmienZakladke('${name}'[, 0-9]*'\(/rejestryVAT/[0-9]*\)'.*\\$#\1#p"`
	if [[ -z "${pdf_url}" ]]; then
		echo "FAILED: cannot find '${name}' id!" >&2
		exit
	fi
	filebase="$YEAR_MONTH taxe - VAT ${name}"
	do_request "${filebase}.html" "${pdf_url}"
	convert_html_to_pdf "${filebase}.html" "${filebase}.pdf"
	rm -f "${filebase}.html"
done

do_post "/dev/null" "/kpir/" "dataOd=${YEAR_MONTH}"
do_request "$YEAR_MONTH taxe - KPiR.pdf" "/kpir/pdf"

do_post "/dev/null" "/st/" "dataOd=${YEAR}-01-01"
do_request "$YEAR_MONTH taxe - ewidencja srodkow trwalych.pdf" "/st/pdf"

rm -f "${tmp_raporty_list}"

do_logout



### taxe v1: get all requests:
# 
# dates_data="dataOd=${FIRST_DAY}&dataDo=${LAST_DAY}"
# 
# do_request "${tmp_raporty_list}" "/raporty/wszystkie/"
# for name in "Raport PIT-5L" "Raport VAT-7" "Raport ZUS"; do
# 	idparam=`grep "${name}\>.*(${YEAR_MONTH})" "${tmp_raporty_list}" | sed -ne 's/^.*\(raport=[0-9][0-9]*\).*$/\1/p'`
# 	if [[ -z "$idparam" ]]; then
# 		echo "FAILED: cannot find '${name}' id!" >&2
# 		exit
# 	fi
# 	do_get_to_pdf \
# 			"$YEAR_MONTH taxe - $name.pdf" \
# 			"/ajax_raporty.php?print=1&${idparam}"
# done
# rm -f "$tmp_raporty_list"
# 
# do_post_to_pdf \
# 		"$YEAR_MONTH taxe - VAT sprzedaz.pdf" \
# 		"/rejestry/sprzedazVAT/?tab=sprzedazVAT" \
# 		"${dates_data}"
# 
# do_post_to_pdf \
# 		"$YEAR_MONTH taxe - VAT nabycia srodkow trwalych.pdf" \
# 		"/rejestry/nabyciaST/?tab=nabyciaST" \
# 		"${dates_data}" 
# 
# do_post_to_pdf \
# 		"$YEAR_MONTH taxe - VAT nabycia pozostale.pdf" \
# 		"/rejestry/pozostaleNabycia/?tab=pozostaleNabycia" \
# 		"${dates_data}" 
# 
# do_post_to_pdf \
# 		"$YEAR_MONTH taxe - KPiR.pdf" \
# 		"/kpir/" \
# 		"dataOd=${YEAR_MONTH}"
# 
# do_logout
# 
###
