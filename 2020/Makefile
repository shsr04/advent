
ifndef prog
	$(error "'prog' not defined")
endif

default: run

run:
	terraform fmt $(prog)
	terraform apply -auto-approve $(prog)