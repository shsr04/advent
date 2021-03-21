
ifndef prog
	$(error "'prog' not defined")
endif

default: run

run:
	terraform fmt -recursive $(prog)
	terraform init $(prog)
	terraform apply -auto-approve -lock=false $(prog)