replacements = {
    "\u00a0": " ",   # non-breaking space
    "\u202f": " ",   # narrow non-breaking space
    "\u2009": " ",   # thin space
    "\u2002": " ",   # en space
    "\u2003": " ",   # em space
    "\u200b": "",    # zero-width space
    "\ufeff": "",    # zero-width no-break space / BOM

    "\u2018": "'",   # left single quote
    "\u2019": "'",   # right single quote / apostrophe
    "\u201a": "'",   # single low-9 quote
    "\u201b": "'",   # single high-reversed-9 quote

    "\u201c": '"',   # left double quote
    "\u201d": '"',   # right double quote
    "\u201e": '"',   # double low-9 quote
    "\u201f": '"',   # double high-reversed-9 quote

    "\u2010": "-",   # hyphen
    "\u2011": "-",   # non-breaking hyphen
    "\u2012": "-",   # figure dash
    "\u2013": "-",   # en dash
    "\u2014": "-",   # em dash
    "\u2015": "-",   # horizontal bar
    "\u2212": "-",   # minus sign

    "\u2026": "...", # ellipsis
    "\u2022": "-",   # bullet
    "\u00b7": "-",   # middle dot
    "\u25cf": "-",   # black circle bullet

    "\u00d7": "x",   # multiplication sign
    "\u00f7": "/",   # division sign

    "\u00ae": "",    # registered sign
    "\u00a9": "",    # copyright sign
    "\u2122": "",    # trademark sign

    "\u00bc": "1/4", # fractions
    "\u00bd": "1/2",
    "\u00be": "3/4",

    "\u2153": "1/3",
    "\u2154": "2/3",
    "\u2155": "1/5",
    "\u2156": "2/5",
    "\u2157": "3/5",
    "\u2158": "4/5",
    "\u2159": "1/6",
    "\u215a": "5/6",
    "\u215b": "1/8",
    "\u215c": "3/8",
    "\u215d": "5/8",
    "\u215e": "7/8",

    "\u20b9": "Rs.", # Indian rupee
    "\u00a3": "GBP", # pound
    "\u20ac": "EUR", # euro
    "\u0024": "$",   # dollar stays same, usually no need
}
