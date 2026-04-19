#!/bin/bash
cd "C:/Users/Lenovo/Downloads/Bitsom/Assignment Module 4(A + B)/ml-assessment-pranav-singhal"
rm -f .gitignore
rm -f push_to_github.sh
rm -rf .git
git init
git config user.name "Pranav Singhal"
git config user.email "pranavsinghal77@gmail.com"
git checkout -b main
git add -A
git commit -m "ML Assessment submission - Pranav Singhal"
git remote add origin https://github.com/pranavsinghal77/ml-assessment-pranav-singhal.git
git push -f origin main
echo ""
echo "Done! Check https://github.com/pranavsinghal77/ml-assessment-pranav-singhal"
