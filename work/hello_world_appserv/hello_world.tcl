proc req_init { } {

	# Write the header
	tpBufAddHdr "Content-type"  "text/html; charset=utf-8"

	# write xml
	tpBufWrite "hello world"
}

proc req_end { } {

	# some stuff to end
}

proc main_init { } {

	# some stuff to init
}

