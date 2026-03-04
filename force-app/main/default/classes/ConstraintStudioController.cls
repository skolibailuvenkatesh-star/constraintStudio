public with sharing class ConstraintStudioController {
    
    @AuraEnabled(cacheable=true)
    public static List<CMLSnippet__c> getCMLSnippets(String recordId, String objectApiName, String searchTerm, String cacheBuster) {
        try {
            String query = 'SELECT Id, Name, Label__c, CML__c, Type__c FROM CMLSnippet__c WHERE Type__c = \'constraint\'';
            
            // Filter by parent record based on object type
            if (objectApiName == 'Product2') {
                query += ' AND ParentProduct2__c = :recordId';
            } else if (objectApiName == 'ProductClassification') {
                query += ' AND ParentProductClassification__c = :recordId';
            }
            
            // Add search filter if provided (ignore cacheBuster in search)
            String actualSearchTerm = searchTerm;
            if (String.isNotBlank(searchTerm) && searchTerm.contains('|')) {
                actualSearchTerm = searchTerm.substringBefore('|');
            }
            
            if (String.isNotBlank(actualSearchTerm)) {
                String searchPattern = '%' + actualSearchTerm + '%';
                query += ' AND (Label__c LIKE :searchPattern OR Name LIKE :searchPattern)';
            }
            
            query += ' ORDER BY Label__c ASC NULLS LAST, Name ASC';
            
            List<CMLSnippet__c> snippets = Database.query(query);
            
            // Transform Product2 IDs back to names for display
            for (CMLSnippet__c snippet : snippets) {
                if (String.isNotBlank(snippet.CML__c)) {
                    snippet.CML__c = transformProduct2IdsToNames(snippet.CML__c);
                }
            }
            
            return snippets;
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching CML Snippets: ' + e.getMessage());
        }
    }
    
    /**
     * @description Transforms Product2 IDs and ProductRelatedComponent IDs in CML back to names for display
     * @param cml The CML string containing Product2_<ID> and REL_ProductRelatedComponent_<ID> references
     * @return String The CML with names instead of IDs
     */
    private static String transformProduct2IdsToNames(String cml) {
        String result = cml;
        
        // First, handle REL_ProductComponentGroup_<ID>[Product2_<ID>] patterns
        Pattern pcgPattern = Pattern.compile('REL_ProductComponentGroup_([a-zA-Z0-9]{15,18})\\[Product2_([a-zA-Z0-9]{15,18})\\]');
        Matcher pcgMatcher = pcgPattern.matcher(cml);
        
        // Collect all ProductComponentGroup IDs and Product2 IDs
        Set<Id> pcgIds = new Set<Id>();
        Set<Id> product2IdsInPcg = new Set<Id>();
        while (pcgMatcher.find()) {
            try {
                pcgIds.add(pcgMatcher.group(1));
                product2IdsInPcg.add(pcgMatcher.group(2));
            } catch (Exception e) {
                // Invalid ID, skip
            }
        }
        
        if (!pcgIds.isEmpty()) {
            // Query ProductComponentGroup names
            Map<Id, String> pcgNameMap = new Map<Id, String>();
            for (ProductComponentGroup pcg : [
                SELECT Id, Name
                FROM ProductComponentGroup
                WHERE Id IN :pcgIds
            ]) {
                String cleanName = pcg.Name.replaceAll('[^a-zA-Z0-9]', '_');
                pcgNameMap.put(pcg.Id, cleanName);
            }
            
            // Query Product2 names
            Map<Id, String> product2NameMap = new Map<Id, String>();
            for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Id IN :product2IdsInPcg]) {
                String cleanName = p.Name.replaceAll('[^a-zA-Z0-9]', '_');
                product2NameMap.put(p.Id, cleanName);
            }
            
            // Replace REL_ProductComponentGroup_<ID>[Product2_<ID>] with GroupName[ProductName]
            pcgMatcher.reset();
            while (pcgMatcher.find()) {
                String pcgId = pcgMatcher.group(1);
                String product2Id = pcgMatcher.group(2);
                if (pcgNameMap.containsKey(pcgId) && product2NameMap.containsKey(product2Id)) {
                    String groupName = pcgNameMap.get(pcgId);
                    String productName = product2NameMap.get(product2Id);
                    String replacement = groupName + '[' + productName + ']';
                    String pattern = 'REL_ProductComponentGroup_' + pcgId + '\\[Product2_' + product2Id + '\\]';
                    result = result.replaceAll(pattern, replacement);
                }
            }
        }
        
        // Second, handle REL_ProductRelatedComponent_<ID>[Product2_<ID>] patterns
        Pattern prcPattern = Pattern.compile('REL_ProductRelatedComponent_([a-zA-Z0-9]{15,18})\\[Product2_([a-zA-Z0-9]{15,18})\\]');
        Matcher prcMatcher = prcPattern.matcher(result);
        
        // Collect all ProductRelatedComponent IDs
        Set<Id> prcIds = new Set<Id>();
        while (prcMatcher.find()) {
            try {
                prcIds.add(prcMatcher.group(1));
            } catch (Exception e) {
                // Invalid ID, skip
            }
        }
        
        if (!prcIds.isEmpty()) {
            // Query ProductRelatedComponent with group and product names
            Map<Id, Map<String, String>> prcDataMap = new Map<Id, Map<String, String>>();
            for (ProductRelatedComponent prc : [
                SELECT Id, ProductComponentGroup.Name, ChildProduct.Name
                FROM ProductRelatedComponent
                WHERE Id IN :prcIds
            ]) {
                String groupCleanName = prc.ProductComponentGroup.Name.replaceAll('[^a-zA-Z0-9]', '_');
                String productCleanName = prc.ChildProduct.Name.replaceAll('[^a-zA-Z0-9]', '_');
                prcDataMap.put(prc.Id, new Map<String, String>{
                    'groupName' => groupCleanName,
                    'productName' => productCleanName
                });
            }
            
            // Replace REL_ProductRelatedComponent_<ID>[Product2_<ID>] with GroupName[ProductName]
            prcMatcher.reset();
            while (prcMatcher.find()) {
                String prcId = prcMatcher.group(1);
                String product2Id = prcMatcher.group(2);
                if (prcDataMap.containsKey(prcId)) {
                    Map<String, String> data = prcDataMap.get(prcId);
                    String replacement = data.get('groupName') + '[' + data.get('productName') + ']';
                    String pattern = 'REL_ProductRelatedComponent_' + prcId + '\\[Product2_' + product2Id + '\\]';
                    result = result.replaceAll(pattern, replacement);
                }
            }
        }
        
        // Then handle remaining Product2_<ID> patterns (not in brackets)
        Pattern product2Pattern = Pattern.compile('Product2_([a-zA-Z0-9]{15,18})');
        Matcher product2Matcher = product2Pattern.matcher(result);
        
        // Collect all Product2 IDs
        Set<Id> product2Ids = new Set<Id>();
        while (product2Matcher.find()) {
            try {
                product2Ids.add(product2Matcher.group(1));
            } catch (Exception e) {
                // Invalid ID, skip
            }
        }
        
        if (!product2Ids.isEmpty()) {
            // Query Product2 names
            Map<Id, String> idToNameMap = new Map<Id, String>();
            for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Id IN :product2Ids]) {
                String cleanName = p.Name.replaceAll('[^a-zA-Z0-9]', '_');
                idToNameMap.put(p.Id, cleanName);
            }
            
            // Replace IDs with names
            for (Id productId : idToNameMap.keySet()) {
                String productName = idToNameMap.get(productId);
                result = result.replaceAll('Product2_' + productId, productName);
            }
        }
        
        return result;
    }
    
    @AuraEnabled
    public static void deleteCMLSnippet(String snippetId) {
        try {
            CMLSnippet__c snippet = [SELECT Id FROM CMLSnippet__c WHERE Id = :snippetId LIMIT 1];
            delete snippet;
        } catch (Exception e) {
            throw new AuraHandledException('Error deleting CML Snippet: ' + e.getMessage());
        }
    }
    
    @AuraEnabled
    public static CMLSnippet__c saveCMLSnippet(String snippetId, String label, String cml) {
        try {
            CMLSnippet__c snippet = [SELECT Id, Label__c, CML__c FROM CMLSnippet__c WHERE Id = :snippetId LIMIT 1];
            snippet.Label__c = label;
            snippet.CML__c = cml;
            update snippet;
            return snippet;
        } catch (Exception e) {
            throw new AuraHandledException('Error saving CML Snippet: ' + e.getMessage());
        }
    }
    
    @AuraEnabled
    public static CMLSnippet__c createCMLSnippet(String recordId, String objectApiName, String keyword, String label) {
        try {
            CMLSnippet__c snippet = new CMLSnippet__c();
            snippet.Label__c = label;
            snippet.Type__c = keyword == 'global' ? 'global' : 'constraint';
            snippet.Object__c = objectApiName;

            // Set the default CML based on keyword
            snippet.CML__c = keyword == 'global' ? '' : keyword + '();';
            
            // Set the parent lookup based on object type
            if (objectApiName == 'Product2') {
                snippet.ParentProduct2__c = recordId;
            } else if (objectApiName == 'ProductClassification') {
                snippet.ParentProductClassification__c = recordId;
            }
            
            insert snippet;
            
            // Return the created snippet with all fields
            return [SELECT Id, Name, Label__c, CML__c, Type__c FROM CMLSnippet__c WHERE Id = :snippet.Id LIMIT 1];
        } catch (Exception e) {
            throw new AuraHandledException('Error creating CML Snippet: ' + e.getMessage());
        }
    }
    
    @AuraEnabled
    public static CMLSnippet__c getGlobalSnippet(String recordId, String objectApiName) {
        try {
            String query = 'SELECT Id, Name, Label__c, CML__c, Type__c FROM CMLSnippet__c WHERE Type__c = \'global\'';
            if (objectApiName == 'Product2') {
                query += ' AND ParentProduct2__c = :recordId';
            } else if (objectApiName == 'ProductClassification') {
                query += ' AND ParentProductClassification__c = :recordId';
            }
            query += ' LIMIT 1';
            List<CMLSnippet__c> results = Database.query(query);
            return results.isEmpty() ? null : results[0];
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching global snippet: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getProductContext(String recordId, String objectApiName) {
        try {
            List<Map<String, Object>> productAttributes = new List<Map<String, Object>>();
            List<Map<String, Object>> classificationAttributes = new List<Map<String, Object>>();
            List<Map<String, Object>> bundleTree = new List<Map<String, Object>>();
            String classificationName = '';

            if (objectApiName == 'Product2') {
                Product2 product = [SELECT Id, Name, BasedOnId, BasedOn.Name FROM Product2 WHERE Id = :recordId LIMIT 1];

                // Product-level attributes with domain
                productAttributes = fetchAttributesForProduct(recordId);

                // Classification attributes with domain
                if (product.BasedOnId != null) {
                    classificationName = product.BasedOn.Name;
                    classificationAttributes = fetchAttributesForClassification(product.BasedOnId);
                }

                // Recursive bundle hierarchy (flat tree with depth)
                buildBundleTree(recordId, 0, bundleTree, new Set<Id>());

            } else if (objectApiName == 'ProductClassification') {
                classificationName = [SELECT Name FROM ProductClassification WHERE Id = :recordId LIMIT 1].Name;
                classificationAttributes = fetchAttributesForClassification(Id.valueOf(recordId));
            }

            return new Map<String, Object>{
                'productAttributes' => productAttributes,
                'classificationAttributes' => classificationAttributes,
                'classificationName' => classificationName,
                'bundleTree' => bundleTree
            };
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching product context: ' + e.getMessage());
        }
    }

    private static List<Map<String, Object>> fetchAttributesForProduct(Id product2Id) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        List<ProductAttributeDefinition> pads = [
            SELECT AttributeDefinition.DeveloperName, AttributeDefinition.DataType,
                   AttributeDefinition.PicklistId
            FROM ProductAttributeDefinition
            WHERE Product2Id = :product2Id
            AND AttributeDefinition.IsActive = true
            ORDER BY AttributeDefinition.DeveloperName
        ];

        Set<Id> picklistIds = new Set<Id>();
        for (ProductAttributeDefinition pad : pads) {
            if (pad.AttributeDefinition.PicklistId != null) picklistIds.add(pad.AttributeDefinition.PicklistId);
        }
        Map<Id, List<String>> picklistMap = bulkFetchPicklistValues(picklistIds);

        for (ProductAttributeDefinition pad : pads) {
            Map<String, Object> attr = new Map<String, Object>{
                'name' => pad.AttributeDefinition.DeveloperName,
                'dataType' => pad.AttributeDefinition.DataType
            };
            if (pad.AttributeDefinition.PicklistId != null && picklistMap.containsKey(pad.AttributeDefinition.PicklistId)) {
                attr.put('domain', picklistMap.get(pad.AttributeDefinition.PicklistId));
            }
            result.add(attr);
        }
        return result;
    }

    private static List<Map<String, Object>> fetchAttributesForClassification(Id classificationId) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        List<ProductClassificationAttr> pcas = [
            SELECT AttributeDefinition.DeveloperName, AttributeDefinition.DataType,
                   AttributeDefinition.PicklistId
            FROM ProductClassificationAttr
            WHERE ProductClassificationId = :classificationId
            AND AttributeDefinition.IsActive = true
            ORDER BY AttributeDefinition.DeveloperName
        ];

        Set<Id> picklistIds = new Set<Id>();
        for (ProductClassificationAttr pca : pcas) {
            if (pca.AttributeDefinition.PicklistId != null) picklistIds.add(pca.AttributeDefinition.PicklistId);
        }
        Map<Id, List<String>> picklistMap = bulkFetchPicklistValues(picklistIds);

        for (ProductClassificationAttr pca : pcas) {
            Map<String, Object> attr = new Map<String, Object>{
                'name' => pca.AttributeDefinition.DeveloperName,
                'dataType' => pca.AttributeDefinition.DataType
            };
            if (pca.AttributeDefinition.PicklistId != null && picklistMap.containsKey(pca.AttributeDefinition.PicklistId)) {
                attr.put('domain', picklistMap.get(pca.AttributeDefinition.PicklistId));
            }
            result.add(attr);
        }
        return result;
    }

    private static Map<Id, List<String>> bulkFetchPicklistValues(Set<Id> picklistIds) {
        Map<Id, List<String>> result = new Map<Id, List<String>>();
        if (picklistIds.isEmpty()) return result;
        for (AttributePicklistValue apv : [
            SELECT Name, PicklistId FROM AttributePicklistValue
            WHERE PicklistId IN :picklistIds ORDER BY PicklistId, Sequence ASC
        ]) {
            if (!result.containsKey(apv.PicklistId)) result.put(apv.PicklistId, new List<String>());
            result.get(apv.PicklistId).add(apv.Name);
        }
        return result;
    }

    private static void buildBundleTree(Id parentProductId, Integer depth, List<Map<String, Object>> tree, Set<Id> visited) {
        if (visited.contains(parentProductId) || depth > 4) return; // prevent infinite loops
        visited.add(parentProductId);

        List<ProductComponentGroup> pcgs = [
            SELECT Id, Name, MaxBundleComponents
            FROM ProductComponentGroup
            WHERE ParentProductId = :parentProductId
            ORDER BY Name
        ];

        Set<Id> pcgIds = new Set<Id>();
        for (ProductComponentGroup pcg : pcgs) pcgIds.add(pcg.Id);
        if (pcgIds.isEmpty()) return;

        List<ProductRelatedComponent> prcs = [
            SELECT Id, ProductComponentGroupId, ChildProductId, ChildProduct.Name, ChildProduct.BasedOnId
            FROM ProductRelatedComponent
            WHERE ProductComponentGroupId IN :pcgIds
            ORDER BY ChildProduct.Name
        ];

        // Collect all child product IDs to bulk-fetch attributes
        Set<Id> childProductIds = new Set<Id>();
        for (ProductRelatedComponent prc : prcs) {
            if (prc.ChildProductId != null) childProductIds.add(prc.ChildProductId);
        }

        // Bulk fetch attributes for all child products
        Map<Id, List<Map<String, Object>>> childAttrMap = new Map<Id, List<Map<String, Object>>>();
        if (!childProductIds.isEmpty()) {
            List<ProductAttributeDefinition> pads = [
                SELECT Product2Id, AttributeDefinition.DeveloperName,
                       AttributeDefinition.DataType, AttributeDefinition.PicklistId
                FROM ProductAttributeDefinition
                WHERE Product2Id IN :childProductIds
                AND AttributeDefinition.IsActive = true
                ORDER BY Product2Id, AttributeDefinition.DeveloperName
            ];

            Set<Id> picklistIds = new Set<Id>();
            for (ProductAttributeDefinition pad : pads) {
                if (pad.AttributeDefinition.PicklistId != null) picklistIds.add(pad.AttributeDefinition.PicklistId);
            }
            Map<Id, List<String>> picklistMap = bulkFetchPicklistValues(picklistIds);

            for (ProductAttributeDefinition pad : pads) {
                if (!childAttrMap.containsKey(pad.Product2Id)) {
                    childAttrMap.put(pad.Product2Id, new List<Map<String, Object>>());
                }
                Map<String, Object> attr = new Map<String, Object>{
                    'name' => pad.AttributeDefinition.DeveloperName,
                    'dataType' => pad.AttributeDefinition.DataType
                };
                if (pad.AttributeDefinition.PicklistId != null && picklistMap.containsKey(pad.AttributeDefinition.PicklistId)) {
                    attr.put('domain', picklistMap.get(pad.AttributeDefinition.PicklistId));
                }
                childAttrMap.get(pad.Product2Id).add(attr);
            }
        }

        // Check which children are bundles (have their own PCGs)
        Set<Id> bundleChildIds = new Set<Id>();
        if (!childProductIds.isEmpty()) {
            for (ProductComponentGroup childPcg : [
                SELECT ParentProductId FROM ProductComponentGroup WHERE ParentProductId IN :childProductIds
            ]) {
                bundleChildIds.add(childPcg.ParentProductId);
            }
        }

        // Group PRCs by PCG
        Map<Id, List<ProductRelatedComponent>> prcsByPcg = new Map<Id, List<ProductRelatedComponent>>();
        for (ProductRelatedComponent prc : prcs) {
            if (!prcsByPcg.containsKey(prc.ProductComponentGroupId)) {
                prcsByPcg.put(prc.ProductComponentGroupId, new List<ProductRelatedComponent>());
            }
            prcsByPcg.get(prc.ProductComponentGroupId).add(prc);
        }

        // Build flat tree
        for (ProductComponentGroup pcg : pcgs) {
            // Add group node
            tree.add(new Map<String, Object>{
                'id' => pcg.Id,
                'depth' => depth,
                'nodeType' => 'group',
                'name' => pcg.Name,
                'maxQty' => pcg.MaxBundleComponents != null ? String.valueOf(pcg.MaxBundleComponents) : '999'
            });

            List<ProductRelatedComponent> groupPrcs = prcsByPcg.get(pcg.Id);
            if (groupPrcs == null) continue;

            for (ProductRelatedComponent prc : groupPrcs) {
                Boolean isBundle = bundleChildIds.contains(prc.ChildProductId);
                List<Map<String, Object>> attrs = childAttrMap.containsKey(prc.ChildProductId)
                    ? childAttrMap.get(prc.ChildProductId) : new List<Map<String, Object>>();

                tree.add(new Map<String, Object>{
                    'id' => prc.ChildProductId,
                    'depth' => depth + 1,
                    'nodeType' => isBundle ? 'bundle' : 'product',
                    'name' => prc.ChildProduct.Name,
                    'attributes' => attrs
                });

                // Recurse into child bundles
                if (isBundle) {
                    buildBundleTree(prc.ChildProductId, depth + 2, tree, visited);
                }
            }
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getAttributeDefinitions(String recordId, String objectApiName) {
        try {
            Set<String> attributeNames = new Set<String>();
            
            if (objectApiName == 'ProductClassification') {
                // Get ProductClassificationAttr related to the current ProductClassification
                List<ProductClassificationAttr> pcAttrs = [
                    SELECT AttributeDefinition.DeveloperName 
                    FROM ProductClassificationAttr 
                    WHERE ProductClassificationId = :recordId 
                    AND AttributeDefinition.DeveloperName != null
                ];
                
                for (ProductClassificationAttr pcAttr : pcAttrs) {
                    attributeNames.add(pcAttr.AttributeDefinition.DeveloperName);
                }
                
            } else if (objectApiName == 'Product2') {
                // Path #1: Get attributes via BasedOn ProductClassification
                Product2 product = [
                    SELECT BasedOnId 
                    FROM Product2 
                    WHERE Id = :recordId 
                    LIMIT 1
                ];
                
                if (product.BasedOnId != null) {
                    List<ProductClassificationAttr> pcAttrs = [
                        SELECT AttributeDefinition.DeveloperName 
                        FROM ProductClassificationAttr 
                        WHERE ProductClassificationId = :product.BasedOnId 
                        AND AttributeDefinition.DeveloperName != null
                    ];
                    
                    for (ProductClassificationAttr pcAttr : pcAttrs) {
                        attributeNames.add(pcAttr.AttributeDefinition.DeveloperName);
                    }
                }
                
                // Path #2: Get attributes via ProductAttributeDefinition
                List<ProductAttributeDefinition> padList = [
                    SELECT AttributeDefinitionId, AttributeDefinition.DeveloperName 
                    FROM ProductAttributeDefinition 
                    WHERE Product2Id = :recordId 
                    AND AttributeDefinition.DeveloperName != null
                ];
                
                for (ProductAttributeDefinition pad : padList) {
                    attributeNames.add(pad.AttributeDefinition.DeveloperName);
                }
            }
            
            // Convert to list with type and display name
            List<Map<String, String>> result = new List<Map<String, String>>();
            List<String> sortedNames = new List<String>(attributeNames);
            sortedNames.sort();
            
            for (String attrName : sortedNames) {
                result.add(new Map<String, String>{
                    'type' => 'Attribute',
                    'value' => attrName,
                    'displayName' => 'Attribute: ' + attrName,
                    'color' => 'blue'
                });
            }
            
            return result;
            
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching attribute definitions: ' + e.getMessage());
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getProductComponentSuggestions(String recordId) {
        try {
            List<Map<String, String>> result = new List<Map<String, String>>();
            
            // Get all ProductComponentGroups for this Product2
            List<ProductComponentGroup> pcgList = [
                SELECT Id, Name, MaxBundleComponents
                FROM ProductComponentGroup
                WHERE ParentProductId = :recordId
            ];
            
            // Get all ProductRelatedComponents for these groups to check if they have children
            Set<Id> pcgIds = new Set<Id>();
            for (ProductComponentGroup pcg : pcgList) {
                pcgIds.add(pcg.Id);
            }
            
            List<ProductRelatedComponent> prcList = [
                SELECT Id, ProductComponentGroupId
                FROM ProductRelatedComponent
                WHERE ProductComponentGroupId IN :pcgIds
            ];
            
            // Group PRCs by PCG to check which groups have children
            Map<Id, List<ProductRelatedComponent>> prcByPcg = new Map<Id, List<ProductRelatedComponent>>();
            for (ProductRelatedComponent prc : prcList) {
                if (!prcByPcg.containsKey(prc.ProductComponentGroupId)) {
                    prcByPcg.put(prc.ProductComponentGroupId, new List<ProductRelatedComponent>());
                }
                prcByPcg.get(prc.ProductComponentGroupId).add(prc);
            }
            
            // Only add ProductComponentGroups (no individual Product2 records)
            for (ProductComponentGroup pcg : pcgList) {
                List<ProductRelatedComponent> relatedComponents = prcByPcg.get(pcg.Id);
                if (relatedComponents == null || relatedComponents.size() == 0) {
                    continue;
                }
                
                // Add ProductComponentGroup
                String cleanName = pcg.Name.replaceAll('[^a-zA-Z0-9]', '_');
                result.add(new Map<String, String>{
                    'type' => 'ProductComponentGroup',
                    'value' => 'REL_ProductComponentGroup_' + pcg.Id,
                    'displayName' => 'Product Component Group: ' + cleanName,
                    'actualName' => cleanName,
                    'color' => 'purple',
                    'recordId' => pcg.Id
                });
            }
            
            return result;
            
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching product component suggestions: ' + e.getMessage());
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getPicklistValues(String recordId, String objectApiName, String attributeName) {
        try {
            List<Map<String, String>> result = new List<Map<String, String>>();
            
            // Find the AttributeDefinition for this attribute
            List<AttributeDefinition> attrDefs = [
                SELECT Id, PicklistId
                FROM AttributeDefinition
                WHERE DeveloperName = :attributeName
                LIMIT 1
            ];
            
            if (attrDefs.isEmpty() || attrDefs[0].PicklistId == null) {
                return result; // No picklist found
            }
            
            Id picklistId = attrDefs[0].PicklistId;
            
            // Get picklist values
            List<AttributePicklistValue> picklistValues = [
                SELECT Id, Value
                FROM AttributePicklistValue
                WHERE PicklistId = :picklistId
                ORDER BY Value ASC
            ];
            
            for (AttributePicklistValue pv : picklistValues) {
                result.add(new Map<String, String>{
                    'type' => 'PicklistValue',
                    'value' => pv.Value,
                    'displayName' => pv.Value,
                    'color' => '#F59E0B' // Orange color for picklist values
                });
            }
            
            return result;
            
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching picklist values: ' + e.getMessage());
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static Map<String, String> findProductRelatedComponent(String productComponentGroupId, String product2Id) {
        try {
            // Get the ProductComponentGroup
            ProductComponentGroup pcg = [
                SELECT Id, Name, MaxBundleComponents
                FROM ProductComponentGroup
                WHERE Id = :productComponentGroupId
                LIMIT 1
            ];
            
            // Find the ProductRelatedComponent that links this group to this product
            List<ProductRelatedComponent> prcList = [
                SELECT Id, ProductComponentGroup.Name, ChildProduct.Name, ChildProduct.BasedOnId
                FROM ProductRelatedComponent
                WHERE ProductComponentGroupId = :productComponentGroupId
                AND ChildProductId = :product2Id
                LIMIT 1
            ];
            
            if (prcList.isEmpty()) {
                return null;
            }
            
            ProductRelatedComponent prc = prcList[0];
            String groupCleanName = prc.ProductComponentGroup.Name.replaceAll('[^a-zA-Z0-9]', '_');
            String productCleanName = prc.ChildProduct.Name.replaceAll('[^a-zA-Z0-9]', '_');
            
            // Check if this group meets the special criteria
            Boolean useProductComponentGroup = false;
            
            if (pcg.MaxBundleComponents == 1) {
                // Get all products in this group to check if they have same BasedOnId
                List<ProductRelatedComponent> allPrcs = [
                    SELECT ChildProduct.BasedOnId
                    FROM ProductRelatedComponent
                    WHERE ProductComponentGroupId = :productComponentGroupId
                ];
                
                Id firstBasedOnId = null;
                Boolean allSameBasedOn = true;
                Boolean allHaveBasedOn = true;
                
                for (ProductRelatedComponent p : allPrcs) {
                    if (p.ChildProduct.BasedOnId == null) {
                        allHaveBasedOn = false;
                        break;
                    }
                    if (firstBasedOnId == null) {
                        firstBasedOnId = p.ChildProduct.BasedOnId;
                    } else if (firstBasedOnId != p.ChildProduct.BasedOnId) {
                        allSameBasedOn = false;
                        break;
                    }
                }
                
                useProductComponentGroup = allSameBasedOn && allHaveBasedOn;
            }
            
            return new Map<String, String>{
                'prcId' => prc.Id,
                'groupId' => pcg.Id,
                'groupName' => groupCleanName,
                'productName' => productCleanName,
                'useProductComponentGroup' => String.valueOf(useProductComponentGroup)
            };
            
        } catch (Exception e) {
            throw new AuraHandledException('Error finding ProductRelatedComponent: ' + e.getMessage());
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getContextualProducts(String contextId, String contextType) {
        try {
            List<Map<String, String>> result = new List<Map<String, String>>();
            
            if (contextType == 'ProductComponentGroup') {
                // Get all products for this ProductComponentGroup
                List<ProductRelatedComponent> prcList = [
                    SELECT Id, ChildProductId, ChildProduct.Name
                    FROM ProductRelatedComponent
                    WHERE ProductComponentGroupId = :contextId
                ];
                
                for (ProductRelatedComponent prc : prcList) {
                    String cleanName = prc.ChildProduct.Name.replaceAll('[^a-zA-Z0-9]', '_');
                    result.add(new Map<String, String>{
                        'type' => 'Product',
                        'value' => 'Product2_' + prc.ChildProductId,
                        'displayName' => 'Product: ' + cleanName,
                        'actualName' => cleanName,
                        'color' => 'green',
                        'recordId' => prc.ChildProductId
                    });
                }
                
            } else if (contextType == 'ProductRelatedComponent') {
                // Get the specific product for this ProductRelatedComponent
                ProductRelatedComponent prc = [
                    SELECT Id, ChildProductId, ChildProduct.Name
                    FROM ProductRelatedComponent
                    WHERE Id = :contextId
                    LIMIT 1
                ];
                
                String cleanName = prc.ChildProduct.Name.replaceAll('[^a-zA-Z0-9]', '_');
                result.add(new Map<String, String>{
                    'type' => 'Product',
                    'value' => 'Product2_' + prc.ChildProductId,
                    'displayName' => 'Product: ' + cleanName,
                    'actualName' => cleanName,
                    'color' => 'green',
                    'recordId' => prc.ChildProductId
                });
            }
            
            return result;
            
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching contextual products: ' + e.getMessage());
        }
    }

    /**
     * @description Imports default-included products from a bundle's ProductComponentGroups
     * and creates initial CML snippets. Only includes components where IsDefault=true.
     * @param recordId The parent Product2 (bundle) ID
     * @return List<CMLSnippet__c> The created snippets
     */
    @AuraEnabled
    public static List<CMLSnippet__c> importBundleProducts(String recordId) {
        try {
            // Get all ProductComponentGroups for this bundle
            List<ProductComponentGroup> pcgList = [
                SELECT Id, Name, MinBundleComponents, MaxBundleComponents
                FROM ProductComponentGroup
                WHERE ParentProductId = :recordId
                ORDER BY Name ASC
            ];

            if (pcgList.isEmpty()) {
                throw new AuraHandledException('No ProductComponentGroups found for this product bundle.');
            }

            Set<Id> pcgIds = new Set<Id>();
            for (ProductComponentGroup pcg : pcgList) {
                pcgIds.add(pcg.Id);
            }

            // Only get default-included components
            List<ProductRelatedComponent> prcList = [
                SELECT Id, ProductComponentGroupId, ProductComponentGroup.Name,
                       ChildProductId, ChildProduct.Name, ChildProduct.BasedOnId,
                       MinQuantity, MaxQuantity
                FROM ProductRelatedComponent
                WHERE ProductComponentGroupId IN :pcgIds
                AND IsDefaultComponent = true
                ORDER BY ProductComponentGroup.Name, ChildProduct.Name
            ];

            // Group PRCs by PCG
            Map<Id, List<ProductRelatedComponent>> prcByPcg = new Map<Id, List<ProductRelatedComponent>>();
            for (ProductRelatedComponent prc : prcList) {
                if (!prcByPcg.containsKey(prc.ProductComponentGroupId)) {
                    prcByPcg.put(prc.ProductComponentGroupId, new List<ProductRelatedComponent>());
                }
                prcByPcg.get(prc.ProductComponentGroupId).add(prc);
            }

            // Check existing snippets to avoid duplicates
            List<CMLSnippet__c> existingSnippets = [
                SELECT Id, Label__c
                FROM CMLSnippet__c
                WHERE ParentProduct2__c = :recordId
                AND Type__c = 'constraint'
            ];
            Set<String> existingLabels = new Set<String>();
            for (CMLSnippet__c s : existingSnippets) {
                if (s.Label__c != null) existingLabels.add(s.Label__c);
            }

            // Create a CML snippet for each group with default products
            List<CMLSnippet__c> newSnippets = new List<CMLSnippet__c>();

            for (ProductComponentGroup pcg : pcgList) {
                List<ProductRelatedComponent> prcs = prcByPcg.get(pcg.Id);
                if (prcs == null || prcs.isEmpty()) continue;

                String groupCleanName = pcg.Name.replaceAll('[^a-zA-Z0-9]', '_');

                // Skip if snippet with this label already exists
                if (existingLabels.contains(groupCleanName)) continue;

                // Build CML with default product references
                String cml = '// Group: ' + pcg.Name;
                if (pcg.MinBundleComponents != null || pcg.MaxBundleComponents != null) {
                    cml += ' [' + (pcg.MinBundleComponents != null ? pcg.MinBundleComponents : 0)
                         + '..' + (pcg.MaxBundleComponents != null ? String.valueOf(pcg.MaxBundleComponents) : '*') + ']';
                }
                cml += '\n';

                for (ProductRelatedComponent prc : prcs) {
                    String productCleanName = prc.ChildProduct.Name.replaceAll('[^a-zA-Z0-9]', '_');
                    cml += 'constraint(' + groupCleanName + '[' + productCleanName + ']);\n';
                }

                CMLSnippet__c snippet = new CMLSnippet__c();
                snippet.Label__c = groupCleanName;
                snippet.CML__c = cml;
                snippet.Type__c = 'constraint';
                snippet.Object__c = 'Product2';
                snippet.ParentProduct2__c = recordId;
                newSnippets.add(snippet);
            }

            if (!newSnippets.isEmpty()) {
                insert newSnippets;
            }

            // Return all snippets
            return [
                SELECT Id, Name, Label__c, CML__c, Type__c
                FROM CMLSnippet__c
                WHERE ParentProduct2__c = :recordId
                AND Type__c = 'constraint'
                ORDER BY Label__c ASC NULLS LAST, Name ASC
            ];

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error importing bundle products: ' + e.getMessage());
        }
    }
}
