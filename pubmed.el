;;; pubmed.el --- Interface to PubMed -*- lexical-binding: t; -*-

;; Author: Folkert van der Beek <folkertvanderbeek@xs4all.nl>
;; Created: 2018-05-23
;; Version: 0.1
;; Keywords: pubmed
;; Package-Requires: ((emacs "25.1") (esxml) (s "1.10"))
;; URL: https://gitlab.com/fvdbeek/emacs-pubmed

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This is a GNU Emacs interface to the PubMed database of references on life sciences and biomedical topics.

;; Since May 1, 2018, NCBI limits access to the E-utilities unless you have an API key. See <https://ncbiinsights.ncbi.nlm.nih.gov/2017/11/02/new-api-keys-for-the-e-utilities/>. If you don't have an API key, E-utilities will still work, but you may be limited to fewer requests than allowed with an API key. Any computer (IP address) that submits more than three E-utility requests per second will receive an error message. This limit applies to any combination of requests to EInfo, ESearch, ESummary, EFetch, ELink, EPost, ESpell, and EGquery. 

;; First, you will need an NCBI account. If you don't have one already, register at <https://www.ncbi.nlm.nih.gov/account/>.

;; To create the key, go to the "Settings" page of your NCBI account. (Hint: after signing in, simply click on your NCBI username in the upper right corner of any NCBI page.) You'll see a new "API Key Management" area. Click the "Create an API Key" button, and copy the resulting key.

;; Use the key by setting the value of PUBMED-API_KEY in your .emacs: (setq pubmed-api_key "1234567890abcdefghijklmnopqrstuvwxyz")

;;; Code:

;;;; Requirements

(require 'esxml)
(require 'esxml-query)
(require 'eww)
(require 'json)
(require 's)
(require 'url)

;;;; Variables
(defvar pubmed-api_key ""
  "E-utilities API key.")

;; When using the ID Converter API, the tool and email parameters should be used to identify the application making the request. See <https://www.ncbi.nlm.nih.gov/pmc/tools/id-converter-api/>.
(defvar pubmed-idconv-tool "emacs-pubmed"
  "Tool paramater for the ID Converter API.")

(defvar pubmed-idconv-email "folkertvanderbeek@xs4all.nl"
  "Email parameter for the ID Converter API.")

(defvar pubmed-idconv-url "https://www.ncbi.nlm.nih.gov/pmc/utils/idconv/v1.0/"
  "ID converter URL.")

(defvar pubmed-efetch-url "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
  "EFetch base URL.")

(defvar pubmed-esearch-url "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
  "ESearch base URL.")

(defvar pubmed-espell-url "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/espell.fcgi"
  "ESpell base URL.")

(defvar pubmed-esummary-url "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi"
  "ESummary base URL.")

(defvar pubmed-db "pubmed"
  "Entrez database.")

(defvar pubmed-usehistory "y"
  "Store search results on the Entrez history server for later use.")

;; Integer query key returned by a previous ESearch call. When provided, ESearch will find the intersection of the set specified by query_key and the set retrieved by the query in term (i.e. joins the two with AND). For query_key to function, WebEnv must be assigned an existing WebEnv string and PUBMED-USE-HISTORY must be set to "y".
(defvar pubmed-query_key ""
  "QueryKey, only present if PUBMED-USEHISTORY is \"y\".")

;; Web environment string returned from a previous ESearch, EPost or ELink call. When provided, ESearch will post the results of the search operation to this pre-existing WebEnv, thereby appending the results to the existing environment. In addition, providing WebEnv allows query keys to be used in term so that previous search sets can be combined or limited. As described above, if WebEnv is used, usehistory must be set to "y".
(defvar pubmed-webenv ""
  "WebEnv; only present if PUBMED-USEHISTORY is \"y\".")

;; Sequential index of the first record to be retrieved (default=0, corresponding to the first record of the entire set). This parameter can be used in conjunction with retmax to download an arbitrary subset of records from the input set.
(defvar pubmed-retstart 0
  "Sequential index of the first UID; default=0.")

;; Total number of UIDs from the retrieved set to be shown in the output. If PUBMED-USEHISTORY is set to "y", the remainder of the retrieved set will be stored on the History server; otherwise these UIDs are lost. Increasing retmax allows more of the retrieved UIDs to be included in the output, up to a maximum of 100,000 records. To retrieve more than 100,000 UIDs, submit multiple esearch requests while incrementing the value of retstart.
(defvar pubmed-retmax 500
  "Number of UIDs returned; default=500.")

;; Specifies the method used to sort UIDs in the ESearch output. If PUBMED-USEHISTORY is set to "y", the UIDs are loaded onto the History Server in the specified sort order and will be retrieved in that order by ESummary or EFetch. For PubMed, the default sort order is "most+recent". Valid sort values include:
;; "journal": Records are sorted alphabetically by journal title, and then by publication date.
;; "pub+date": Records are sorted chronologically by publication date (with most recent first), and then alphabetically by journal title.
;; "most+recent": Records are sorted chronologically by date added to PubMed (with the most recent additions first).
;; "relevance": Records are sorted based on relevance to your search. For more information about PubMed's relevance ranking, see the PubMed Help section on Computation of Weighted Relevance Order in PubMed.
;; "title": Records are sorted alphabetically by article title.
;; "author": Records are sorted alphabetically by author name, and then by publication date.
(defvar pubmed-sort ""
  "Method used to sort UIDs in the ESearch output.")

;; There are two allowed values for ESearch: "uilist" (default), which displays the standard output, and "count", which displays only the <Count> tag.
(defvar pubmed-rettype "uilist"
  "Retrieval type.")

;; Determines the format of the returned output. The default value for the E-Utilities is "xml" for ESearch XML, but "json" is also supported to return output in JSON format. Emacs-pubmed uses JSON for Esearch and Esummary calls, but XML for EFetch calls because it doesn't support JSON.
(defvar pubmed-retmode "json"
  "Retrieval mode.")

(defvar pubmed-time-format-string "%Y-%m-%d"
  "The format-string that is used by `format-time-string' to convert time values. Default is the ISO 8601 date format, i.e., \"%Y-%m-%d\".")

(defvar uid nil
  "The entry being displayed in this buffer.")

(defvar pubmed-months '("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")
  "Abbreviated months.")

(defvar unpaywall-url "https://api.unpaywall.org"
  "Unpaywall URL.")

;; The current version of the API is Version 2, and this is the only version supported.
(defvar unpaywall-version "v2"
  "Unpaywall API version.")

;; Requests must include your email as a parameter at the end of the URL, like this: api.unpaywall.org/my/request?email=YOUR_EMAIL.
(defvar unpaywall-email ""
  "E-mail address to authenticate Unpaywall requests.")

;;;; Keymap

(defvar pubmed-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") 'pubmed-show-current-entry)
    (define-key map (kbd "g") 'pubmed-get-unpaywall)
    (define-key map (kbd "n") 'pubmed-show-next)
    (define-key map (kbd "p") 'pubmed-show-prev)
    (define-key map (kbd "q") 'quit-window)
    (define-key map (kbd "s") 'pubmed-search)
    map)
  "Local keymap for `pubmed-mode'.")

;;;; Mode

(define-derived-mode pubmed-mode tabulated-list-mode "pubmed"
  "Major mode for PubMed."
  :group 'pubmed
  (setq tabulated-list-format [("Author" 15 t)
                               ("Title"  75 t)
                               ("Journal" 30 t)
			       ("Pubdate" 0 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key nil)
  (tabulated-list-init-header))

;;;;; Commands
(defun pubmed-show-mode ()
  "Mode for displaying PubMed entries."
  (interactive)
  (use-local-map pubmed-mode-map)
  (setq major-mode 'pubmed-show-mode
        mode-name "pubmed-show"
        buffer-read-only t)
  (buffer-disable-undo))

(defun pubmed-search (query)
  "Search PubMed with QUERY return a vector of UIDs."
  (interactive
   (let ((query (read-string "Query: ")))
     (list query)))
  (pubmed--esearch query))

(defun pubmed-show-entry (uid)
  "Display ENTRY in the current buffer."
  (interactive)
  ;; "Return the parsed summary for an UID"
  ;; TODO: Only the summary of the first UID is returned. Consider returning multiple summaries at once when multiple UIDs are passed as argument.
  (let ((url-request-method "POST")
	 (url-request-extra-headers `(("Content-Type" . "application/x-www-form-urlencoded")))
	 (url-request-data (concat "db=" pubmed-db
				   "&retmode=xml"
				   "&rettype=abstract"
				   "&id=" uid
				   (when (not (string-empty-p pubmed-api_key))
				     (concat "&api_key=" pubmed-api_key)))))
    (url-retrieve pubmed-efetch-url 'pubmed--check-efetch)))

(defun pubmed-show-current-entry ()
  "Show the current entry in the \"pubmed-show\" buffer."
  (interactive)
  (setq uid (tabulated-list-get-id))
  (pubmed-show-entry uid))

(defun pubmed-show-next ()
  "Show the next item in the \"pubmed-show\" buffer."
  (interactive)
  (with-current-buffer "*PubMed*"
    (forward-line)
    (setq uid (tabulated-list-get-id))
    (if (get-buffer-window "*PubMed-entry*" "visible")
	(pubmed-show-entry uid))))

(defun pubmed-show-prev ()
  "Show the previous entry in the \"pubmed-show\" buffer."
  (interactive)
  (with-current-buffer "*PubMed*"
    (forward-line -1)
    (setq uid (tabulated-list-get-id))
    (if (get-buffer-window "*PubMed-entry*" "visible")
	(pubmed-show-entry uid))))

(defun pubmed-convert-id (uid)
  "Return the doi of article UID.  Use commas to separate multiple UIDs. This service allows for conversion of up to 200 UIDs in a single request. If you have a larger number of IDs, split your list into smaller subsets."
  (interactive)
  (let* ((url-request-method "POST")
	 (url-request-extra-headers `(("Content-Type" . "application/x-www-form-urlencoded")))
	 (url-request-data (concat "ids=" uid
				   "&format=json"
				   "&versions=no"
				   "&tool=" pubmed-idconv-tool
				   "&email=" pubmed-idconv-email))
	 (json-object-type 'plist)
         (json-array-type 'list)
         (json-key-type nil)
	 (json (with-current-buffer (url-retrieve-synchronously pubmed-idconv-url) (json-read-from-string (buffer-substring (1+ url-http-end-of-headers) (point-max)))))
	 (records (plist-get json :records))
	 (doi (plist-get (car records) :doi)))
    doi))

(defun pubmed-get-unpaywall ()
  "Fetch fulltext article from Unpaywall"
  (interactive)
  (if uid
      (pubmed--unpaywall uid)
    (message "No entry selected")))

;;;; Functions

(defun pubmed--header-error-p (header)
  "Return t if HEADER is an error code or null header."
  (and (not (null header))
       (<= 400 (string-to-number (cadr header)))))

(defun pubmed--parse-header (header)
  "Return the a list with (HTTP version status text)"
  (string-match "HTTP/\\([0-9]+\\.[0-9]+\\) \\([1-5][0-9][0-9]\\) \\(.*\\)$"
                header)
  (if (match-string 3 header)
      (list (match-string 1 header)
            (match-string 2 header)
            (match-string 3 header))
    (error "Malformed header: %s" header)))

(defun pubmed--get-header-error (header)
  "Given a parsed HEADER from `pubmed--parse-header', return human readable error."
  (if (null header)
      "Null header, probably an error with twit.el."
    (case (string-to-number (cadr header))
      ;; 1xx Informational response
      ((100) "Continue")
      ((101) "Switching Protocols")
      ((102) "Processing (WebDAV; RFC 2518)")
      ((103) "Early Hints (RFC 8297)")
      ;; 2xx Success
      ((200) "OK") ;; Standard response for successful HTTP requests.
      ((201) "Created")
      ((202) "Accepted")
      ((203) "Non-Authoritative Information (since HTTP/1.1)")
      ((204) "No Content")
      ((205) "Reset Content")
      ((206) "Partial Content (RFC 7233)")
      ((207) "Multi-Status (WebDAV; RFC 4918)")
      ((208) "Already Reported (WebDAV; RFC 5842)")
      ((226) "IM Used (RFC 3229)")
      ;; 3xx Redirection
      ((300) "Multiple Choices")
      ((301) "Moved Permanently")
      ((302) "Found")
      ((303) "See Other (since HTTP/1.1)")
      ((304) "Not Modified (RFC 7232)")
      ((305) "Use Proxy (since HTTP/1.1)")
      ((306) "Switch Proxy")
      ((307) "Temporary Redirect (since HTTP/1.1)")
      ((308) "Permanent Redirect (RFC 7538)")
      ;; 4xx Client errors
      ((400) "Bad Request")
      ((401) "Unauthorized (RFC 7235)")
      ((402) "Payment Required")
      ((403) "Forbidden")
      ((404) "Not Found")
      ((405) "Method Not Allowed")
      ((406) "Not Acceptable")
      ((407) "Proxy Authentication Required (RFC 7235)")
      ((408) "Request Timeout")
      ((409) "Conflict")
      ((410) "Gone")
      ((411) "Length Required")
      ((412) "Precondition Failed (RFC 7232)")
      ((413) "Payload Too Large (RFC 7231)")
      ((414) "URI Too Long (RFC 7231)")
      ((415) "Unsupported Media Type")
      ((416) "Range Not Satisfiable (RFC 7233)")
      ((417) "Expectation Failed")
      ((418) "I'm a teapot (RFC 2324, RFC 7168)")
      ((421) "Misdirected Request (RFC 7540)")
      ((422) "Unprocessable Entity (WebDAV; RFC 4918)")
      ((423) "Locked (WebDAV; RFC 4918)")
      ((424) "Failed Dependency (WebDAV; RFC 4918)")
      ((426) "Upgrade Required")
      ((428) "Precondition Required (RFC 6585)")
      ((429) "Too Many Requests (RFC 6585)")
      ((431) "Request Header Fields Too Large (RFC 6585)")
      ((451) "Unavailable For Legal Reasons (RFC 7725)")
      ;; 5xx Server errors
      ((500) "Internal Server Error")
      ((501) "Not Implemented")
      ((502) "Bad Gateway")
      ((503) "Service Unavailable")
      ((504) "Gateway Timeout")
      ((505) "HTTP Version Not Supported")
      ((506) "Variant Also Negotiates (RFC 2295)")
      ((507) "Insufficient Storage (WebDAV; RFC 4918)")
      ((508) "Loop Detected (WebDAV; RFC 5842)")
      ((510) "Not Extended (RFC 2774)")
      ((511) "Network Authentication Required (RFC 6585)"))))

(defun pubmed--parse-time-string (time-string)
  "Convert TIME-STRING to a string formatted according to PUBMED-TIME-FORMAT-STRING. TIME-STRING should be formatted as \"yyyy/mm/dd HH:MM\"."
  (let* ((regexp "\\([0-9][0-9][0-9][0-9]\\)/\\([0-9][0-9]\\)/\\([0-9][0-9]\\) \\([0-9][0-9]\\):\\([0-9][0-9]\\)")
	 (parsed-time (string-match regexp time-string))
	 (sec 0)
	 (min (string-to-number (match-string 5 time-string)))
	 (hour (string-to-number (match-string 4 time-string)))
	 (day (string-to-number (match-string 3 time-string)))
	 (mon (string-to-number (match-string 2 time-string)))
	 (year (string-to-number (match-string 1 time-string)))
	 (encoded-time (encode-time sec min hour day mon year)))
    (format-time-string pubmed-time-format-string encoded-time)))

(defun pubmed--list (entries)
  "Populate the tabulated list mode buffer."
  (let ((pubmed-buffer (get-buffer-create "*PubMed*"))
	(inhibit-read-only t))
    (with-current-buffer pubmed-buffer
      (pubmed-mode)
      (setq tabulated-list-entries (append entries tabulated-list-entries))
      (tabulated-list-print nil t))
    (switch-to-buffer pubmed-buffer)))

(defun pubmed--esearch (query)
  "Search PubMed with QUERY. Use ESearch to retrieve the UIDs and post them on the History server."
  (let* ((hexified-query (url-hexify-string query)) ;  All special characters are URL encoded. 
	 (encoded-query (s-replace "%20" "+" hexified-query)) ; All (hexified) spaces are replaced by '+' signs
	 (url-request-method "POST")
	 (url-request-extra-headers `(("Content-Type" . "application/x-www-form-urlencoded")))
	 (url-request-data (concat "db=" pubmed-db
				   "&retmode=json"
				   "&sort=" pubmed-sort
				   "&term=" encoded-query
				   "&usehistory=" pubmed-usehistory
				   (when (not (string-empty-p pubmed-webenv))
				     (concat "&webenv=" pubmed-webenv))
				   (when (not (string-empty-p pubmed-api_key))
				     (concat "&api_key=" pubmed-api_key)))))
    (message "Searching...")
    (url-retrieve pubmed-esearch-url 'pubmed--check-esearch)))

(defun pubmed--check-esearch (status)
  "Callback function of `pubmed--esearch'. Check the STATUS and HTTP status of the response. Call `pubmed--parse-esearch' when no error occurred."
  (let ((url-error (plist-get status :error))
	;; (url-redirect (plist-get status :redirect))
	(first-header-line (buffer-substring (point-min) (line-end-position))))
    (cond
     (url-error
      (signal (car url-error) (cdr url-error)))
     ;; (url-redirect
     ;;  (message "Redirected-to: %s" (url-redirect)))
     ((pubmed--header-error-p (pubmed--parse-header first-header-line))
      (error "HTTP error: %s" (pubmed--get-header-error (pubmed--parse-header first-header-line))))
     (t
      (pubmed--parse-esearch)))))

(defun pubmed--parse-esearch ()
  "Parse the JSON object in the data retrieved by `pubmed--esearch'. First use ESearch to retrieve the UIDs and post them on the History server, then use multiple ESummary calls to retrieve the data in batches of 500."
  (let* ((json (decode-coding-string (buffer-substring (1+ url-http-end-of-headers) (point-max)) 'utf-8))
	 (json-object-type 'plist)
         (json-array-type 'list)
         (json-key-type nil)
	 (json-object (json-read-from-string json))
	 (esearchresult (plist-get json-object :esearchresult))
	 (error-message (plist-get esearchresult :ERROR))
	 (count (string-to-number (plist-get esearchresult :count)))
	 (retstart (string-to-number (plist-get esearchresult :retstart)))
	 (retmax (string-to-number (plist-get esearchresult :retmax)))
	 (querykey (plist-get esearchresult :querykey))
	 (webenv (plist-get esearchresult :webenv)))
    (cond
     (error-message
      (error error-message))
     ((eq count 0)
      (message "No items found for query"))
     (t
      (progn
	(setq pubmed-webenv webenv)
	(pubmed--get-docsums querykey webenv count retstart retmax))))))

(defun pubmed--get-docsums (querykey webenv count &optional retstart retmax)
  "Use multiple ESummary calls to retrieve the document summaries (DocSums) for a set of UIDs stored on the Entrez History server in batches of 500. The QUERYKEY specifies which of the UID lists attached to the given WEBENV will be used as input to ESummary."
  (interactive)
  (let ((start (if (boundp 'retstart)
		   retstart
		 pubmed-retstart))
	(max (if (boundp 'retmax)
		 retmax
	       pubmed-retmax))
	(pubmed-buffer (get-buffer-create "*PubMed*")))
    (with-current-buffer pubmed-buffer
      ;; Remove previous entries from the `tabulated-list-entries' variable.
      (setq tabulated-list-entries nil))
    (while (< start count)
      ;; Limit the amount of requests to prevent errors like "Too Many Requests (RFC 6585)" and "Bad Request". NCBI mentions a limit of 3 requests/second without an API key and 10 requests/second with an API key (see <https://ncbiinsights.ncbi.nlm.nih.gov/2017/11/02/new-api-keys-for-the-e-utilities/>).
      (if (not (string-empty-p pubmed-api_key))
	  ;; Pause for 0.1 seconds, because of the limit to 10 requests/second with an API key.
	  (run-with-timer "0.1 sec" nil 'pubmed--esummary querykey webenv start max)
	;; Pause for 0.33 seconds, because of the limit to 3 requests/second without an API key.
	(run-with-timer "0.33 sec" nil 'pubmed--esummary querykey webenv start max))
      (setq start (+ start max)))))

(defun pubmed--esummary (querykey webenv retstart retmax)
  "Retrieve the document summaries (DocSums) of a set of UIDs stored on the Entrez History server."
  (let*((url-request-method "POST")
	(url-request-extra-headers `(("Content-Type" . "application/x-www-form-urlencoded")))
	(url-request-data (concat "db=" pubmed-db
				  "&retmode=" pubmed-retmode
				  "&retstart=" (number-to-string retstart)
				  "&retmax=" (number-to-string retmax)
				  "&query_key=" querykey
				  "&webenv=" webenv
				  (when (not (string-empty-p pubmed-api_key))
				    (concat "&api_key=" pubmed-api_key)))))
    (url-retrieve pubmed-esummary-url 'pubmed--check-esummary)))

(defun pubmed--check-esummary (status)
  "Callback function of `pubmed--esummary'.Check the STATUS and HTTP status of the response, and signal an error if an HTTP error occurred. Call `pubmed--parse-esummary' when no error occurred."  
  (let ((url-error (plist-get status :error))
	;; (url-redirect (plist-get status :redirect))
	(first-header-line (buffer-substring (point-min) (line-end-position))))
    (cond
     (url-error
      (signal (car url-error) (cdr url-error)))
     ;; (url-redirect
     ;;  (message "Redirected-to: %s" (url-redirect)))
     ((pubmed--header-error-p (pubmed--parse-header first-header-line))
      (error "HTTP error: %s" (pubmed--get-header-error (pubmed--parse-header first-header-line))))
     (t
      (pubmed--parse-esummary)))))

(defun pubmed--parse-esummary ()
  "Parse the JSON object in the data retrieved by `pubmed--esummary'."
  (let* ((json (decode-coding-string (buffer-substring (1+ url-http-end-of-headers) (point-max)) 'utf-8))
	 (json-object-type 'plist)
         (json-array-type 'list)
         (json-key-type nil)
  	 (json-object (json-read-from-string json))
  	 (result (plist-get json-object :result))
	 (uids (plist-get result :uids))
	 entries)
    ;; The JSON object is converted to a plist. The first keyword is `:uids', with a list of all uids as value. The rest of the keywords are named `:<uid>', with a plist containing the document summary (DocSum) as value.
    ;; Iterate over the list of UIDs, convert them to a keyword, and get the value.
    ;; The  `tabulated-list-entries' variable specifies the entries displayed in the Tabulated List buffer. Each list element corresponds to one entry, and has the form "(ID CONTENTS)", where "ID" is UID and "CONTENTS" is a vector with the same number of elements as `tabulated-list-format'.
    (dolist (uid uids entries)
      (let* ((keyword (intern (concat ":" uid)))
	     (value (plist-get result keyword))
	     (entry (list (plist-get value :uid)
	    		  (vector (plist-get value :sortfirstauthor)
	    			  (plist-get value :title)
	    			  (plist-get value :source)
				  (pubmed--parse-time-string (plist-get value :sortpubdate))
				  ))))
	(push entry entries)))
    (pubmed--list (nreverse entries))))

(defun pubmed--check-efetch (status)
  "Callback function of `pubmed-show-entry'. Check the STATUS and HTTP status of the response. Call `pubmed--parse-efetch' when no error occurred."
  (let ((url-error (plist-get status :error))
	;; (url-redirect (plist-get status :redirect))
	(first-header-line (buffer-substring (point-min) (line-end-position))))
    (cond
     (url-error
      (signal (car url-error) (cdr url-error)))
     ;; (url-redirect
     ;;  (message "Redirected-to: %s" (url-redirect)))
     ((pubmed--header-error-p (pubmed--parse-header first-header-line))
      (error "HTTP error: %s" (pubmed--get-header-error (pubmed--parse-header first-header-line))))
     (t
      (pubmed--parse-efetch)))))

(defun pubmed--parse-efetch ()
  "Parse the XML object in the data retrieved by `pubmed-show-entry' and show the result in the \"*PubMed-entry*\" buffer."
  (let* ((dom (libxml-parse-xml-region (1+ url-http-end-of-headers) (point-max)))
	 (summary (esxml-query "PubmedArticle" dom))
	 (pubmed-entry-buffer (get-buffer-create "*PubMed-entry*"))
	 (inhibit-read-only t))
    (with-current-buffer pubmed-entry-buffer
      (pubmed-show-mode)
      (erase-buffer)
      (insert (pubmed--summary-journal-isoabbreviation summary))
      (insert ". ")
      (insert (pubmed--summary-journal-pubdate summary))
      (insert ";")
      (insert (plist-get (pubmed--summary-journal-issue summary) 'volume))
      (when (plist-get (pubmed--summary-journal-issue summary) 'issue)
      	(insert "(" (plist-get (pubmed--summary-journal-issue summary) 'issue) ")" ))
      (insert ":")
      (insert (pubmed--summary-pagination summary))
      (insert ".\n\n")
      (insert (pubmed--summary-article-title summary))
      (insert "\n")
      (when (pubmed--summary-authors summary)
      	(let ((authorlist (pubmed--summary-authors summary))
      	      authors)
      	  (dolist (author authorlist)
      	    (cond
      	     ((and (plist-get author 'lastname) (plist-get author 'initials))
      	      (push (concat (plist-get author 'lastname) " " (plist-get author 'initials)) authors))
      	     ((plist-get author 'collectivename)
      	      (push (plist-get author 'collectivename) authors))))
      	  (insert (s-join ", " (nreverse authors)))
      	  (insert "\n\n")))
      (when (pubmed--summary-investigators summary)
      	(let ((investigatorlist (pubmed--summary-investigators summary))
      	      investigators)
      	  (dolist (investigator investigatorlist)
      	    (push (concat (plist-get investigator 'lastname) " " (plist-get investigator 'initials)) investigators))
      	  (insert "Collaborators (" (number-to-string (length investigatorlist)) ")\n")
      	  (insert (s-join ", " (nreverse investigators)))
      	  (insert "\n\n")))
      (when (pubmed--summary-abstract summary)
      	(insert "ABSTRACT\n")
      	(insert (pubmed--summary-abstract summary))
      	(insert "\n\n"))
      (when (pubmed--summary-keywords summary)
      	(insert "KEYWORDS: ")
      	(insert (s-join "; " (pubmed--summary-keywords summary)))
      	(insert "\n\n"))
      (when  (plist-get (pubmed--summary-articleid summary) 'pubmed)
      	(insert "PMID: " (plist-get (pubmed--summary-articleid summary) 'pubmed) "\n"))
      (when (plist-get (pubmed--summary-articleid summary) 'doi)
      	(insert "DOI: " (plist-get (pubmed--summary-articleid summary) 'doi) "\n"))
      ;; (when (plist-get (pubmed--summary-articleid summary) 'pii)
      ;; 	(insert "PII: " (plist-get (pubmed--summary-articleid summary) 'pii) "\n"))
      (when (plist-get (pubmed--summary-articleid summary) 'pmc)
      	(insert "PMCID: " (plist-get (pubmed--summary-articleid summary) 'pmc) "\n"))
      (insert "\n")
      (when (pubmed--summary-commentscorrections summary)
      	(insert "Comment in:\n")
      	(let ((commentslist (pubmed--summary-commentscorrections summary)))
      	  (dolist (comment commentslist)
      	    ;; (insert (plist-get comment 'reftype))
      	    (insert (plist-get comment 'refsource))
      	    ;; TODO: make refsource a link
      	    ;; (insert (plist-get comment 'pmid))	    
      	    (insert "\n"))))
      (when (pubmed--summary-references summary)
      	(insert "References in:\n")
      	(let ((referencelist (pubmed--summary-references summary)))
      	  (dolist (reference referencelist)
      	    (insert (plist-get reference 'citation))
      	    ;; TODO: make reference a link
      	    ;; (insert (plist-get reference 'pubmed))
      	    (insert "\n"))))
      (when (pubmed--summary-publicationtype summary)
      	(insert "Publication types:\n")
      	(let ((publicationtypes (pubmed--summary-publicationtype summary)))
      	  (dolist (publicationtype publicationtypes)
      	    (insert (plist-get publicationtype 'type))
      	    (insert "\n"))))
      (when (pubmed--summary-mesh summary)
      	(insert "MeSH terms:\n")
      	(let ((meshheadings (pubmed--summary-mesh summary)))
      	  ;; Iterate over the meshheadings
      	  (dolist (meshheading meshheadings)
      	    (let ((qualifiers (plist-get meshheading 'qualifiers)))
      	      ;; If the descriptor (or subject heading) has qualifiers (or subheadings)
      	      (if qualifiers
      		  ;; Iterate over the qualifiers
      		  (dolist (qualifier qualifiers)
      		    ;; Insert "descriptor/qualifier"
      		    (insert (plist-get meshheading 'descriptor))
      		    (insert "/")
      		    (insert (plist-get qualifier 'qualifier))
      		    (insert "\n"))
      		;; If the descriptor (or subject heading) has no qualifiers (or subheadings)
      		;; Insert "descriptor"		
      		(insert (plist-get meshheading 'descriptor))
      		(insert "\n"))))))
      (when (pubmed--summary-grant summary)
      	(insert "\n")
      	(insert "Grant support:\n")
      	(let ((grants (pubmed--summary-grant summary)))
      	  (dolist (grant grants)
      	    (insert (plist-get grant 'grantid))
      	    (insert "/")
      	    (insert (plist-get grant 'agency))
      	    (insert "/")
      	    (insert (plist-get grant 'country))
      	    (insert "\n"))))
      (goto-char (point-min)))
    (save-selected-window
      (display-buffer pubmed-entry-buffer))))

(defun pubmed--summary-elocation (summary)
  "Return an plist of Elocation IDs of the article SUMMARY.  The plist has the form \"('type TYPE 'id ID)\"."
  (let* ((elocationidlist (esxml-query-all "ELocationID" (esxml-query "PubmedData Article" summary)))
	 elocationids)
    (dolist (elocationid elocationidlist elocationids)
      (let* ((type (intern (esxml-node-attribute 'EIdType elocationid)))
	     (id (car (esxml-node-children elocationid))))
    	(push (list 'type type 'id id) elocationids)))
    (nreverse elocationids)))

(defun pubmed--summary-pmid (summary)
  "Return the PMID of the article SUMMARY"
  (esxml-query "PMID *" summary))

(defun pubmed--summary-datecompleted (summary)
  "Return the completed date of the article SUMMARY. The time value of the date can be converted by `format-time-string' to a string according to FORMAT-STRING."
  (let* ((datecompleted (encode-time 0
				     0
				     0
				     (string-to-number (esxml-query "DateCompleted Day *" summary))
				     (string-to-number (esxml-query "DateCompleted Month *" summary))
				     (string-to-number (esxml-query "DateCompleted Year *" summary)))))
    datecompleted))

(defun pubmed--summary-daterevised (summary)
  "Return the revised date value of the article SUMMARY. The time value of the date can be converted by `format-time-string' to a string according to FORMAT-STRING."
  (let* ((daterevised (encode-time 0
				   0
				   0
				   (string-to-number (esxml-query "DateRevised Day *" summary))
				   (string-to-number (esxml-query "DateRevised Month *" summary))
				   (string-to-number (esxml-query "DateRevised Year *" summary)))))
    daterevised))

(defun pubmed--summary-pubmodel (summary)
  "Return the publication model of the article SUMMARY"
  (esxml-node-attribute 'PubModel (esxml-query "Article" summary)))

(defun pubmed--summary-issn (summary)
  "Return a plist with the journal ISSN and ISSN type of the article SUMMARY. The plist has the form \"('issn ISSN 'type TYPE)\"."
  "Return the ISSN of the article SUMMARY"
  (let ((issn (esxml-query "Journal ISSN *" summary))
	(type (esxml-node-attribute 'IssnType (esxml-query "Journal ISSN" summary))))
    (list 'issn issn 'type type)))

(defun pubmed--summary-journal-issue (summary)
  "Return a plist with the journal year, season, issue, volume, and cited medium of the article SUMMARY. The plist has the form \"('year YEAR 'season SEASON 'issue ISSUE 'volume VOLUME 'citedmedium CITEDMEDIUM)\"."
  (let* ((year (esxml-query "Journal JournalIssue Year *" summary))
	 (season (esxml-query "Journal JournalIssue Season *" summary))
	 (issue (esxml-query "Journal JournalIssue Issue *" summary))
	 (volume (esxml-query "Journal JournalIssue Volume *" summary))
	 (citedmedium (esxml-node-attribute 'CitedMedium (esxml-query "Journal JournalIssue" summary))))
    (list 'year year 'season season 'issue issue 'volume volume 'citedmedium citedmedium)))

(defun pubmed--summary-journal-pubdate (summary)
  "Return the journal publication date of the article SUMMARY."
  (let* ((day (esxml-query "Article Journal JournalIssue PubDate Day *" summary))
	 (month (esxml-query "Article Journal JournalIssue PubDate Month *" summary))
	 (year (esxml-query "Article Journal JournalIssue PubDate Year *" summary)))
    ;; If MONTH is a number
    (when (string-match "[0-9]+" month)
      ;; Convert the month number to the abbreviated month name
	(setq month (nth (1- (string-to-number month)) pubmed-months)))
    (cond
     ((and month day)
      (concat year " " month " " day))
     (month
      (concat year " " month))
     (t
      year))))

(defun pubmed--summary-journal-title (summary)
  "Return the journal title of the article SUMMARY."
  (esxml-query "Journal Title *" summary))

(defun pubmed--summary-journal-isoabbreviation (summary)
  "Return the journal ISO abbreviation of the article SUMMARY."
  (esxml-query "Journal ISOAbbreviation *" summary))

(defun pubmed--summary-article-title (summary)
  "Return the title of the article SUMMARY."
  (esxml-query "Article ArticleTitle *" summary))

(defun pubmed--summary-pagination (summary)
  "Return the pagination of the article SUMMARY."
  (esxml-query "Article Pagination MedlinePgn *" summary))

(defun pubmed--summary-abstract (summary)
  "Return the abstract of the article SUMMARY. Return nil if no abstract is available."
  (let ((textlist (esxml-query-all "AbstractText" (esxml-query "Article Abstract" summary)))
	texts)
    (when textlist
      ;; Iterate through AbstractText nodes, where structure is like: (AbstractText ((Label . "LABEL") (NlmCategory . "CATEGORY")) "ABSTRACTTEXT")
      (dolist (text textlist texts)
	(let ((label (esxml-node-attribute 'Label text))
	      (nlmcategory (esxml-node-attribute 'NlmCategory text)) ; NlmCategory attribute is ignored
	      (abstracttext (car (esxml-node-children text))))
	  (if
	      (and label abstracttext)
	      (push (concat label ": " abstracttext) texts)
	    (push abstracttext texts))))
      (s-join "\n\n" (nreverse texts)))))

(defun pubmed--summary-authors (summary)
  "Return an plist with the authors of the article SUMMARY. Each list element corresponds to one author, and is a plist with the form \"('lastname LASTNAME 'forename FORENAME 'initials INITIALS 'affiliationinfo AFFILIATIONINFO 'collectivename COLLECTIVENAME)\"."
  (let ((authorlist (esxml-query-all "Author" (esxml-query "Article AuthorList" summary)))
authors)
    (dolist (author authorlist)
      (let ((lastname (esxml-query "LastName *" author))
	    (forename (esxml-query "ForeName *" author))
    	    (initials (esxml-query "Initials *" author))
	    (affiliationinfo (esxml-query "AffiliationInfo Affiliation *" author))
    	    (collectivename (esxml-query "CollectiveName *" author)))
    	(push (list 'lastname lastname 'forename forename 'initials initials 'affiliationinfo affiliationinfo 'collectivename collectivename) authors)))
    (nreverse authors)))

(defun pubmed--summary-language (summary)
  "Return the language of the article SUMMARY."
  (esxml-query "Article Language *" summary))

(defun pubmed--summary-grant (summary)
  "Return a list of the grants of the article SUMMARY. Each list element corresponds to one grant, and is a plist with the form \"('grantid GRANTID 'agency AGENCY 'country COUNTRY)\"."
  (let ((grantlist (esxml-query-all "Grant" (esxml-query "Article GrantList" summary)))
	grants) ;; make sure list starts empty
    (dolist (grant grantlist)
      (let ((grantid (esxml-query "GrantID *" grant))
	    (agency (esxml-query "Agency *" grant))
	    (country (esxml-query "Country *" grant)))
	(push (list 'grantid grantid 'agency agency 'country country) grants)))
    (nreverse grants)))

(defun pubmed--summary-publicationtype (summary)
  "Return a plist of the publication types and unique identifiers of the article SUMMARY. The plist has the form \"('type TYPE 'ui UI)\"."
  ;; Iterate through PublicationType nodes, where structure is like: (PublicationType ((UI . "UI")) "PUBLICATIONTYPE")
  (let ((publicationtypelist (esxml-query-all "PublicationType" (esxml-query "Article PublicationTypeList" summary)))
	publicationtypes) ;; make sure list starts empty
    (dolist (publicationtype publicationtypelist publicationtypes)
      (let ((type (car (esxml-node-children publicationtype)))
    	    (ui (esxml-node-attribute 'UI publicationtype)))
	;; For each `publicationtype' push the type to the list `publicationtypes'
	;; Ignore the UI
	(push (list 'type type 'ui ui) publicationtypes)))
    (nreverse publicationtypes)))

(defun pubmed--summary-articledate (summary)
  "Return a plist of article date and date type of the article SUMMARY. The plist has the form \"('type TYPE 'date date)\". The time value of the date can be converted by `format-time-string' to a string according to FORMAT-STRING."
  (let ((type (esxml-node-attribute 'DateType (esxml-query "Article ArticleDate" summary)))
	(date (encode-time 0
			   0
			   0
			   (string-to-number (esxml-query "Article ArticleDate Day *" summary))
			   (string-to-number  (esxml-query "Article ArticleDate Month *" summary))
			   (string-to-number (esxml-query "Article ArticleDate Year *" summary)))))
    (list 'type type 'date date)))

(defun pubmed--summary-medlinejournalinfo (summary)
  "Return a plist with the country, journal title abbreviation (MedlineTA), LocatorPlus accession number (NlmUniqueID) and ISSNLinking element of the article SUMMARY. The plist has the form \"('country COUNTRY 'medlineta MEDLINETA 'nlmuniqueid NLMUNIQUEID 'issnlinking ISSNLINKING)\"."
  (let ((country (esxml-query "MedlineJournalInfo Country *" summary))
	(medlineta (esxml-query "MedlineJournalInfo MedlineTA *" summary))
	(nlmuniqueid (esxml-query "MedlineJournalInfo NlmUniqueID *" summary))
	(issnlinking (esxml-query "MedlineJournalInfo ISSNLinking *" summary)))
    (list 'country country 'medlineta medlineta 'nlmuniqueid nlmuniqueid 'issnlinking issnlinking)))

(defun pubmed--summary-substances (summary)
  "Return a plist of the chemical substances and unique identifiers of the article SUMMARY. Each list element corresponds to one substance, and is a plist with the form \"('registrynumber REGISTRYNUMBER 'substance SUBSTANCE 'ui UI)\"."
  (let ((chemicallist (esxml-query-all "Chemical" (esxml-query "ChemicalList" summary)))
	chemicals)
    (dolist (chemical chemicallist)
      (let ((registrynumber (esxml-query "RegistryNumber *" chemical)) ; RegistryNumber is ignored
	    (substance (esxml-query "NameOfSubstance *" chemical))
	    (ui (esxml-node-attribute 'UI (esxml-query "NameOfSubstance" chemical))))
	(push (list 'registrynumber registrynumber 'substance substance 'ui ui) chemicals)))
    (nreverse chemicals)))

(defun pubmed--summary-mesh (summary)
  "Return an list of the MeSH terms  of the article SUMMARY. Each list element corresponds to one descriptor (or subject heading) and its qualifiers (or subheadings), and is a plist with the form \"('descriptor DESCRIPTOR 'ui UI 'qualifiers (('qualifier QUALIFIER 'ui UI) ('qualifier QUALIFIER 'ui UI) (...)))\"."
  (let ((meshheadinglist (esxml-query-all "MeshHeading" (esxml-query "MeshHeadingList" summary)))
	meshheadings)
    (dolist (meshheading meshheadinglist)
      (let ((descriptorname (esxml-query "DescriptorName *" meshheading))
      	    (descriptorui (esxml-node-attribute 'UI (esxml-query "DescriptorName" meshheading)))
      	    (qualifierlist (esxml-query-all "QualifierName" meshheading))
	    qualifiers)
	(dolist (qualifier qualifierlist)
	  (let ((qualifiername (esxml-query "QualifierName *" qualifier))
      		(qualifierui (esxml-node-attribute 'UI (esxml-query "QualifierName" qualifier))))
	    (push (list 'qualifier qualifiername 'ui qualifierui) qualifiers)))
	(push (list 'descriptor descriptorname 'ui descriptorui 'qualifiers qualifiers) meshheadings)))
    (nreverse meshheadings)))

(defun pubmed--summary-commentscorrections (summary)
  "Return the correction of the article SUMMARY. The plist has the form \"('reftype REFTYPE 'refsource REFSOURCE 'pmid PMID)\"."
  (let ((commentscorrectionslist (esxml-query-all "CommentsCorrections" (esxml-query "CommentsCorrectionsList" summary)))
	commentscorrections)
    (dolist (commentscorrection commentscorrectionslist commentscorrections)
      (let ((reftype (esxml-node-attribute 'RefType commentscorrection))
	    (refsource (esxml-query "RefSource *" commentscorrection))
	    (pmid (esxml-query "PMID *" commentscorrection)))
	;; For each `commentscorrection' push the reftype, refsource and pmid to the list `commentscorrections'
    	(push (list 'reftype reftype 'refsource refsource 'pmid pmid) commentscorrections)))
    (nreverse commentscorrections)))

(defun pubmed--summary-articleid (summary)
  "Return an plist of the article IDs. The plist has the form \"('pubmed pubmed 'doi DOI 'pii PII 'pmc PMC 'mid MID)\"."
  (let ((articleidlist (esxml-query-all "ArticleId" (esxml-query "PubmedData ArticleIdList" summary)))
	articleids)
    (dolist (articleid articleidlist articleids)
      (let ((idtype (intern (esxml-node-attribute 'IdType articleid)))
	    (id (car (esxml-node-children articleid))))
	(push idtype articleids)
	(push id articleids)))
    (nreverse articleids)))

(defun pubmed--summary-keywords (summary)
  "Return an alist of the article keywords."
  (let ((keywordlist (esxml-query-all "Keyword" (esxml-query "KeywordList" summary)))
	keywords)
    (dolist (keyword keywordlist)
      (push (car (esxml-node-children keyword)) keywords))
    (nreverse keywords)))

(defun pubmed--summary-investigators (summary)
  "Return an plist with the investigators of the article SUMMARY. Each list element corresponds to one investigator, and is a plist with the form \"('lastname LASTNAME 'forename FORENAME 'initials INITIALS)\"."
  (let ((investigatorlist (esxml-query-all "Investigator" (esxml-query "InvestigatorList" summary)))
	investigators)
    (dolist (investigator investigatorlist investigators)
      (let ((lastname (esxml-query "LastName *" investigator))
	    (forename (esxml-query "ForeName *" investigator))
    	    (initials (esxml-query "Initials *" investigator)))
    	(push (list 'lastname lastname 'forename forename 'initials initials) investigators)))
    (nreverse investigators)))

(defun pubmed--summary-references (summary)
  "Return a plist of the references of the article SUMMARY. Each list element corresponds to one reference, The has the form \"('citation CITATION 'pubmed PMID)\"."
  (let ((referencelist (esxml-query-all "Reference" (esxml-query "ReferenceList" summary)))
	references)
    (dolist (reference referencelist)
      (let ((citation (esxml-query "Citation *" reference))
	    (articleidlist (esxml-query-all "ArticleId" (esxml-query "ArticleIdList" reference))))
	(dolist (articleid articleidlist)
	  (let ((idtype (intern (esxml-node-attribute 'IdType articleid)))
		(id (car (esxml-node-children articleid))))
	    (push (list 'citation citation idtype id) references)))))
    (nreverse references)))

(defun pubmed--unpaywall (uid)
  "Return buffer of Unpaywall request. Retrieve the response of a POST request with the DOI of the currently selected PubMed entry and call `pubmed--parse-unpaywall' with the current buffer containing the reponse."
  (let* ((doi (pubmed-convert-id uid))
	 (url-request-method "GET")
	 (url (concat unpaywall-url "/" unpaywall-version "/" doi))
	 (arguments (concat "?email=" unpaywall-email)))
    (message "doi: %s" doi)
    (url-retrieve (concat url arguments) 'pubmed--check-unpaywall)))
  
(defun pubmed--check-unpaywall (status)
  "Callback function of `pubmed--unpaywall'. Check the STATUS and HTTP status of the response. Call `pubmed--parse-unpaywall' when no error occurred."
  (let ((url-error (plist-get status :error))
	;; (url-redirect (plist-get status :redirect))
	(first-header-line (buffer-substring (point-min) (line-end-position))))
    (cond
     (url-error
      (signal (car url-error) (cdr url-error)))
     ;; (url-redirect
     ;;  (message "Redirected-to: %s" (url-redirect)))
     ((pubmed--header-error-p (pubmed--parse-header first-header-line))
      (error "HTTP error: %s" (pubmed--get-header-error (pubmed--parse-header first-header-line))))
     (t
      (pubmed--parse-unpaywall)))))

(defun pubmed--parse-unpaywall ()
  "Parse the JSON object in the data retrieved by `pubmed--unpaywall'."
  (let* ((json (decode-coding-string (buffer-substring (1+ url-http-end-of-headers) (point-max)) 'utf-8))
	 (json-object-type 'plist)
         (json-array-type 'list)
         (json-key-type nil)
	 (json-object (json-read-from-string json))
	 (best_oa_location (plist-get json-object :best_oa_location))
	 (url_for_pdf (plist-get best_oa_location :url_for_pdf)))
    (if url_for_pdf
	(progn
	  (message "URL for PDF: %s" url_for_pdf)
	  (url-retrieve url_for_pdf 'pubmed--unpaywall-pdf (list url_for_pdf)))
      (message "No pdf found"))))

(defun pubmed--unpaywall-pdf (status url)
  "Retrieve URL for PDF."
  (let* ((headers (eww-parse-headers))
	 (content-type
	  (mail-header-parse-content-type
           (if (zerop (length (cdr (assoc "content-type" headers))))
	       "text/plain"
             (cdr (assoc "content-type" headers)))))
	 (buffer (generate-new-buffer "*Unpaywall*")))
    (with-current-buffer buffer
      (erase-buffer)
      (insert (format "Loading %s..." url))
      (goto-char (point-min)))
    (save-selected-window
      (switch-to-buffer-other-frame buffer))
    (if
	(equal (car content-type) "application/pdf")
	(progn
	  (message "Content-type: %s" (car content-type))
	  (let ((data (buffer-substring (1+ url-http-end-of-headers) (point-max))))
	    (with-current-buffer buffer
       	      (set-buffer-file-coding-system 'binary)
	      (erase-buffer)
	      (insert data)
      	      (pdf-view-mode))))
      (eww-display-raw buffer))))

;;;; Footer

(provide 'pubmed)

;;; pubmed.el ends here