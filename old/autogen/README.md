# Autogen

generate component (individual or integration) tests


## Setup

```bash
pip install --user pytest tree-sitter tree-sitter-cpp jinja2 pyyaml
```

## Generate the test

* In main.py, set selected_components at the top of main() to the components you want to test.
* Optionally, set test_name in main.py to give the test a unique name.
* Prepare a CSV file with the required input data. The expected CSV header format is printed in the terminal.
* Run all commands below from the project folder.
* Generated files are placed under ./out/<test_name>/.

```bash
python3 main.py
```

## Run the test

put the csv file under: ./out/<test name>/.

```bash
cd ./out/<test name>/. && \
sh build.sh && sh run.sh
```
