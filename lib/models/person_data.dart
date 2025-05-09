// Data model for person
class PersonData {
  final String name;
  final String id;
  final String department;
  final String section;
  final List<double> embedding;

  PersonData({
    required this.name,
    required this.id,
    required this.department,
    required this.section,
    required this.embedding,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'id': id,
    'department': department,
    'section': section,
    'embedding': embedding,
  };

  factory PersonData.fromJson(Map<String, dynamic> json) => PersonData(
    name: json['name'],
    id: json['id'],
    department: json['department'],
    section: json['section'],
    embedding: List<double>.from(json['embedding']),
  );
}
