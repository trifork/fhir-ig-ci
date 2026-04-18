Profile: CiSamplePatient
Parent: Patient
Id: ci-sample-patient
Title: "CI Sample Patient"
Description: "A trivial Patient profile used only to verify that sushi runs end-to-end inside the fhir-ig-ci image."
* name 1..* MS
* birthDate MS

Instance: CiSamplePatientExample
InstanceOf: CiSamplePatient
Title: "CI Sample Patient Example"
Description: "Example instance conforming to CiSamplePatient."
Usage: #example
* name.family = "Doe"
* name.given = "Jane"
* birthDate = "1980-01-01"
